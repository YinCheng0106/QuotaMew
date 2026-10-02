import AppKit
import Darwin
import Foundation

protocol CodexRateLimitsReading: Sendable {
    func readRateLimits() async throws -> CodexRateLimitsResult
}

protocol CodexRuntimeDiagnosticReading: Sendable {
    func runtimeDiagnostic() async -> ProviderRuntimeDiagnostic
}

enum CodexAppServerError: Error, Equatable, Sendable {
    case executableNotFound
    case launchFailed
    case timeout
    case responseTooLarge
    case invalidResponse
    case serverError(code: Int?)
    case noResponse
    case requestCapacityExceeded
}

extension CodexAppServerError: ProviderStatusProvidingError {
    var providerStatus: ProviderStatus {
        switch self {
        case .executableNotFound:
            .notInstalled
        case .launchFailed:
            .failed(.runtimeLaunchFailed)
        case .timeout, .responseTooLarge, .invalidResponse, .serverError, .noResponse, .requestCapacityExceeded:
            .failed(.refreshFailed)
        }
    }
}

actor CodexAppServerClient: CodexRateLimitsReading, CodexRuntimeDiagnosticReading {
    private static let initializeRequestID = 1
    private static let firstRequestID = 2
    // Bounded caller interests, including active and queued coalesced batches.
    static let maximumRequestWaiters = 128

    private let executableURL: URL?
    private let locator: CodexExecutableLocator?
    private let arguments: [String]
    private let timeout: Duration
    private let activityTimeout: Duration
    private let maximumResponseBytes: Int
    private let lifecycle: CodexConnectionLifecycle

    private struct RequestBatch {
        let generation: UInt64
        let method: CodexRequestMethod
        var waiters: [UUID: CheckedContinuation<CodexTransportResult, Error>]
        var task: Task<Void, Never>?
    }

    private var nextRequestID = firstRequestID
    private var nextRequestGeneration: UInt64 = 1
    private var activeRequest: RequestBatch?
    private var pendingQuota: RequestBatch?
    private var pendingActivity: RequestBatch?
    private var isShutdown = false
    private var hasStartedAppServerProcess = false
    private var lastRequestSucceeded = false
    private var lastFailureCategory: DiagnosticFailureCategory?

    init(
        executableURL: URL,
        arguments: [String] = ["app-server"],
        timeout: Duration = .seconds(5),
        activityTimeout: Duration = .seconds(2),
        maximumResponseBytes: Int = 1_048_576,
        notificationCenter: NotificationCenter = .default
    ) {
        self.executableURL = executableURL
        self.locator = nil
        self.arguments = arguments
        self.timeout = timeout
        self.activityTimeout = activityTimeout
        self.maximumResponseBytes = max(maximumResponseBytes, 1)
        self.lifecycle = CodexConnectionLifecycle(notificationCenter: notificationCenter)
    }

    init(
        locator: CodexExecutableLocator,
        timeout: Duration = .seconds(5),
        activityTimeout: Duration = .seconds(2),
        maximumResponseBytes: Int = 1_048_576,
        notificationCenter: NotificationCenter = .default
    ) {
        self.executableURL = nil
        self.locator = locator
        self.arguments = ["app-server"]
        self.timeout = timeout
        self.activityTimeout = activityTimeout
        self.maximumResponseBytes = max(maximumResponseBytes, 1)
        self.lifecycle = CodexConnectionLifecycle(notificationCenter: notificationCenter)
    }

    func readRateLimits() async throws -> CodexRateLimitsResult {
        do {
            guard case .rateLimits(let result) = try await request(.rateLimits) else {
                throw CodexAppServerError.invalidResponse
            }
            lastRequestSucceeded = true
            lastFailureCategory = nil
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastRequestSucceeded = false
            lastFailureCategory = Self.failureCategory(for: error)
            throw error
        }
    }

    // Transport only: no activity-domain mapping, persistence, or production caller yet.
    // Activity may reuse a healthy quota connection, but never launches/reconnects one.
    func readAccountUsageTransport() async throws -> CodexAccountUsageTransportResult {
        guard case .accountUsage(let result) = try await request(.accountUsage) else {
            throw CodexAppServerError.invalidResponse
        }
        return result
    }

    func runtimeDiagnostic() async -> ProviderRuntimeDiagnostic {
        let discovery: CodexRuntimeDiscovery
        if let locator {
            discovery = locator.diagnosticSnapshot()
        } else {
            let isDetected = executableURL.map {
                FileManager.default.isExecutableFile(atPath: $0.path)
            } ?? false
            discovery = CodexRuntimeDiscovery(
                chatGPTApplication: DiagnosticHostApplicationState(
                    application: .chatGPT,
                    isDetected: false,
                    version: nil
                ),
                runtimeSource: isDetected ? .standaloneCodex : .notDetected,
                runtimeDetected: isDetected,
                failureCategory: isDetected ? nil : .runtimeNotDetected
            )
        }

        let isConnected = lifecycle.connection?.isHealthy == true
        let appServerState: DiagnosticAppServerState
        if isConnected {
            appServerState = .connected
        } else if lastFailureCategory == .appServerLaunchFailed {
            appServerState = .launchFailed
        } else if hasStartedAppServerProcess {
            appServerState = .disconnected
        } else {
            appServerState = .notStarted
        }

        let compatibilityStatus: DiagnosticCompatibilityStatus
        if lastRequestSucceeded {
            compatibilityStatus = .compatible
        } else if discovery.runtimeDetected {
            compatibilityStatus = .unverified
        } else {
            compatibilityStatus = .unavailable
        }

        return ProviderRuntimeDiagnostic(
            hostApplication: discovery.chatGPTApplication,
            runtimeSource: discovery.runtimeSource,
            runtimeDetected: discovery.runtimeDetected,
            compatibilityStatus: compatibilityStatus,
            appServerState: appServerState,
            lastFailureCategory: lastFailureCategory ?? discovery.failureCategory
        )
    }

    func shutdown() async {
        isShutdown = true
        let task = activeRequest?.task
        task?.cancel()
        for batch in [pendingQuota, pendingActivity] {
            batch?.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        pendingQuota = nil
        pendingActivity = nil
        if let connection = lifecycle.beginShutdown() {
            await connection.stop()
        }
        await task?.value
    }

    private func request(_ method: CodexRequestMethod) async throws -> CodexTransportResult {
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let result: CodexTransportResult = try await withCheckedThrowingContinuation { continuation in
                // No suspension between cancellation check, admission and registration.
                guard !Task.isCancelled, !isShutdown else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard waiterCount < Self.maximumRequestWaiters else {
                    continuation.resume(throwing: CodexAppServerError.requestCapacityExceeded)
                    return
                }
                admit(method, waiterID: waiterID, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private var waiterCount: Int {
        (activeRequest?.waiters.count ?? 0) + (pendingQuota?.waiters.count ?? 0)
            + (pendingActivity?.waiters.count ?? 0)
    }

    private func admit(
        _ method: CodexRequestMethod,
        waiterID: UUID,
        continuation: CheckedContinuation<CodexTransportResult, Error>
    ) {
        // Keep quota coalescing. New activity demand waits behind already queued quota.
        if activeRequest?.method == method,
           activeRequest?.task?.isCancelled == false,
           method == .rateLimits || pendingQuota == nil {
            activeRequest?.waiters[waiterID] = continuation
            return
        }
        var batch = method == .rateLimits ? pendingQuota : pendingActivity
        if batch == nil {
            batch = RequestBatch(generation: nextRequestGeneration, method: method, waiters: [:])
            nextRequestGeneration &+= 1
        }
        batch?.waiters[waiterID] = continuation
        if method == .rateLimits { pendingQuota = batch } else { pendingActivity = batch }
        startNextRequest()
    }

    private func startNextRequest() {
        guard activeRequest == nil, !isShutdown else { return }
        if let quota = pendingQuota {
            activeRequest = quota
            pendingQuota = nil
        } else if let activity = pendingActivity {
            activeRequest = activity
            pendingActivity = nil
        } else {
            return
        }
        guard let batch = activeRequest else { return }
        activeRequest?.task = Task {
            let result: Result<CodexTransportResult, Error>
            do { result = .success(try await performRequest(batch.method)) }
            catch { result = .failure(error) }
            finishRequest(generation: batch.generation, result: result)
        }
    }

    private func finishRequest(generation: UInt64, result: Result<CodexTransportResult, Error>) {
        guard let batch = activeRequest, batch.generation == generation else { return }
        // performRequest has cleared correlation and fully awaited any reader/process cleanup.
        activeRequest = nil
        batch.waiters.values.forEach { $0.resume(with: result) }
        startNextRequest()
    }

    private func cancelWaiter(_ id: UUID) {
        if let waiter = activeRequest?.waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
            if activeRequest?.waiters.isEmpty == true { activeRequest?.task?.cancel() }
            // The cancelled worker retains the slot through disconnect/reap/reader completion.
        } else if let waiter = pendingQuota?.waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
            if pendingQuota?.waiters.isEmpty == true { pendingQuota = nil }
        } else if let waiter = pendingActivity?.waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
            if pendingActivity?.waiters.isEmpty == true { pendingActivity = nil }
        }
    }

    #if DEBUG
    // Admission synchronization for deterministic transport tests; no payload or runtime polling.
    func requestQueueCounts() -> (active: Int, quota: Int, activity: Int) {
        (activeRequest?.waiters.count ?? 0, pendingQuota?.waiters.count ?? 0,
         pendingActivity?.waiters.count ?? 0)
    }
    #endif

    private func performRequest(_ method: CodexRequestMethod) async throws -> CodexTransportResult {
        try Task.checkCancellation()
        let connection: ManagedCodexConnection
        if method == .rateLimits {
            connection = try await healthyConnection()
        } else {
            guard let healthy = lifecycle.connection, healthy.isHealthy else {
                throw CodexAppServerError.noResponse
            }
            connection = healthy
        }
        let requestID = nextRequestID
        nextRequestID = nextRequestID == Int.max ? Self.firstRequestID : nextRequestID + 1
        defer { connection.clearExpectedResponse() }

        do {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try connection.writeRequest(CodexRequest(id: requestID, method: method))
                return try await response(
                    id: requestID, from: connection,
                    timeout: method == .rateLimits ? timeout : activityTimeout
                )
            } onCancel: {
                connection.requestStop()
            }
        } catch {
            // A consumed, correlated usage error cannot desynchronize the stream.
            // Quota retains its existing disconnect-on-failure policy.
            if method == .rateLimits || !connection.isHealthy
                || !connection.hasConsumedResponse {
                await disconnect(connection)
            }
            try Task.checkCancellation()
            throw error
        }
    }

    private func healthyConnection() async throws -> ManagedCodexConnection {
        if let connection = lifecycle.connection, connection.isHealthy {
            #if DEBUG
            RuntimeDiagnostics.shared.codexConnectionBecameHealthy(
                processID: connection.processIdentifier
            )
            #endif
            return connection
        }

        if let staleConnection = lifecycle.takeConnection() {
            await staleConnection.stop()
        }
        try Task.checkCancellation()

        guard let executableURL = locator?.locate() ?? executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        // Never buffer provider stderr in QuotaMew.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            hasStartedAppServerProcess = true
        } catch {
            try? standardInput.fileHandleForWriting.close()
            try? standardOutput.fileHandleForReading.close()
            process.standardInput = nil
            process.standardOutput = nil
            throw CodexAppServerError.launchFailed
        }

        #if DEBUG
        RuntimeDiagnostics.shared.codexProcessStarted(process.processIdentifier)
        #endif

        let connection = ManagedCodexConnection(
            process: process,
            input: standardInput.fileHandleForWriting,
            output: standardOutput.fileHandleForReading,
            maximumResponseBytes: maximumResponseBytes
        )

        do {
            try connection.writeInitialization(id: Self.initializeRequestID)
            guard lifecycle.install(connection) else {
                await connection.stop()
                throw CancellationError()
            }
            #if DEBUG
            RuntimeDiagnostics.shared.codexConnectionBecameHealthy(
                processID: connection.processIdentifier
            )
            #endif
            return connection
        } catch {
            await connection.stop()
            throw error
        }
    }

    private func response(
        id: Int,
        from connection: ManagedCodexConnection,
        timeout: Duration
    ) async throws -> CodexTransportResult {
        return try await withThrowingTaskGroup(of: CodexTransportResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await connection.response(for: id)
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                connection.markTimedOutAndRequestStop()
                throw CodexAppServerError.timeout
            }

            guard let result = try await group.next() else {
                throw CodexAppServerError.noResponse
            }

            group.cancelAll()
            return result
        }
    }

    private func disconnect(_ connection: ManagedCodexConnection) async {
        lifecycle.remove(connection)
        await connection.stop()
    }

    private static func failureCategory(for error: Error) -> DiagnosticFailureCategory? {
        guard let error = error as? CodexAppServerError else { return .refreshFailed }
        switch error {
        case .executableNotFound:
            return .runtimeNotDetected
        case .launchFailed:
            return .appServerLaunchFailed
        case .timeout, .noResponse:
            return .appServerConnectionFailed
        case .responseTooLarge, .invalidResponse, .serverError, .requestCapacityExceeded:
            return .rpcUnavailable
        }
    }
}

private enum CodexRequestMethod: String, Encodable, Sendable {
    case rateLimits = "account/rateLimits/read"
    case accountUsage = "account/usage/read"
}

private struct CodexRequest: Encodable, Sendable {
    let id: Int
    let method: CodexRequestMethod
}

private enum CodexTransportResult: Sendable {
    case rateLimits(CodexRateLimitsResult)
    case accountUsage(CodexAccountUsageTransportResult)
}

private struct CodexResponseHeader: Decodable {
    let id: Int?
}

private struct CodexResponsePayload<Value: Decodable>: Decodable {
    let result: Value?
    let error: CodexAppServerResponseError?

    private enum CodingKeys: String, CodingKey { case result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(CodexAppServerResponseError.self, forKey: .error)
        result = error == nil ? try container.decodeIfPresent(Value.self, forKey: .result) : nil
    }
}

private struct CodexAppServerEnvelope: Sendable {
    let id: Int
    let result: Result<CodexTransportResult, CodexAppServerError>
}

private struct CodexAppServerResponseError: Decodable, Sendable {
    let code: Int?
}

private final class CodexConnectionLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var currentConnection: ManagedCodexConnection?
    private var terminationObserver: NSObjectProtocol?
    private var isShutdown = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.shutdownSynchronously()
        }
    }

    deinit {
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
        }
        shutdownSynchronously()
    }

    var connection: ManagedCodexConnection? {
        lock.withLock { currentConnection }
    }

    func install(_ connection: ManagedCodexConnection) -> Bool {
        let installation: (accepted: Bool, oldConnection: ManagedCodexConnection?) = lock.withLock {
            guard !isShutdown else { return (accepted: false, oldConnection: nil) }
            let oldConnection = currentConnection
            currentConnection = connection
            return (accepted: true, oldConnection: oldConnection)
        }
        installation.oldConnection?.requestStop()
        return installation.accepted
    }

    func remove(_ connection: ManagedCodexConnection) {
        lock.withLock {
            guard currentConnection === connection else { return }
            currentConnection = nil
        }
    }

    func takeConnection() -> ManagedCodexConnection? {
        lock.withLock {
            defer { currentConnection = nil }
            return currentConnection
        }
    }

    func beginShutdown() -> ManagedCodexConnection? {
        lock.withLock {
            isShutdown = true
            defer { currentConnection = nil }
            return currentConnection
        }
    }

    private func shutdownSynchronously() {
        beginShutdown()?.requestStop()
    }
}

private final class ExpectedCodexResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var request: CodexRequest?
    private var consumed = false

    func set(_ request: CodexRequest?) {
        lock.withLock {
            self.request = request
            consumed = false
        }
    }

    // Claim exactly once so duplicate responses cannot replace the one-element buffer.
    func consume(_ requestID: Int?) -> CodexRequestMethod? {
        lock.withLock {
            guard let request, requestID == request.id else { return nil }
            self.request = nil
            consumed = true
            return request.method
        }
    }

    var hasConsumedResponse: Bool { lock.withLock { consumed } }
}

private final class ManagedCodexConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let responses: AsyncThrowingStream<CodexAppServerEnvelope, Error>
    private let responseContinuation: AsyncThrowingStream<CodexAppServerEnvelope, Error>.Continuation
    private let expectedResponse = ExpectedCodexResponse()
    private let stdoutTask: Task<Void, Never>

    private var didRequestStop = false
    private var didFinishStop = false
    private var didTimeOut = false

    init(
        process: Process,
        input: FileHandle,
        output: FileHandle,
        maximumResponseBytes: Int
    ) {
        self.process = process
        self.input = input
        self.output = output

        let channel = AsyncThrowingStream<CodexAppServerEnvelope, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        responses = channel.stream
        responseContinuation = channel.continuation

        let expectedResponse = expectedResponse
        stdoutTask = Task.detached(priority: .utility) {
            await CodexStdoutReader.run(
                output: output,
                maximumResponseBytes: maximumResponseBytes,
                expectedResponse: expectedResponse,
                continuation: channel.continuation
            )
        }

        #if DEBUG
        RuntimeDiagnostics.shared.codexStdoutReaderStarted(
            processID: process.processIdentifier
        )
        #endif
    }

    deinit {
        requestStop()
    }

    var isHealthy: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !didRequestStop && process.isRunning
    }

    var processIdentifier: pid_t {
        process.processIdentifier
    }

    func writeInitialization(id: Int) throws {
        struct Initialize: Encodable {
            struct Params: Encodable {
                struct ClientInfo: Encodable {
                    let name = "quota_pulse"
                    let title = "QuotaMew"
                    let version = "0.1.0"
                }
                let clientInfo = ClientInfo()
            }
            let method = "initialize"
            let id: Int
            let params = Params()
        }
        struct Initialized: Encodable {
            struct Params: Encodable {}
            let method = "initialized"
            let params = Params()
        }
        var data = try JSONEncoder().encode(Initialize(id: id))
        data.append(0x0A)
        data.append(try JSONEncoder().encode(Initialized()))
        data.append(0x0A)
        try write(data)
    }

    func writeRequest(_ request: CodexRequest) throws {
        expectedResponse.set(request)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try write(data)
    }

    var hasConsumedResponse: Bool { expectedResponse.hasConsumedResponse }

    func clearExpectedResponse() { expectedResponse.set(nil) }

    func response(for requestID: Int) async throws -> CodexTransportResult {
        do {
            for try await envelope in responses {
                guard envelope.id == requestID else { continue }

                return try envelope.result.get()
            }
        } catch {
            if timedOut {
                throw CodexAppServerError.timeout
            }
            try Task.checkCancellation()
            throw error
        }

        throw timedOut ? CodexAppServerError.timeout : CodexAppServerError.noResponse
    }

    func markTimedOutAndRequestStop() {
        condition.lock()
        didTimeOut = true
        condition.unlock()
        requestStop()
    }

    func requestStop() {
        condition.lock()
        if didRequestStop {
            while !didFinishStop {
                condition.wait()
            }
            condition.unlock()
            return
        }
        didRequestStop = true
        condition.unlock()

        #if DEBUG
        RuntimeDiagnostics.shared.codexConnectionStopping(
            processID: process.processIdentifier
        )
        #endif

        responseContinuation.finish(throwing: CancellationError())
        stdoutTask.cancel()
        try? input.close()
        try? output.close()

        if process.isRunning {
            process.terminate()
        }

        for _ in 0..<50 where process.isRunning {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // Foundation has already observed and reaped the child once isRunning becomes false.
        if process.isRunning {
            process.waitUntilExit()
        }

        condition.lock()
        didFinishStop = true
        condition.broadcast()
        condition.unlock()

        #if DEBUG
        RuntimeDiagnostics.shared.codexProcessStopped(process.processIdentifier)
        #endif
    }

    func stop() async {
        requestStop()
        await stdoutTask.value
        #if DEBUG
        RuntimeDiagnostics.shared.codexStdoutReaderStopped(
            processID: process.processIdentifier
        )
        #endif
    }

    private var timedOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didTimeOut
    }

    private func write(_ data: Data) throws {
        condition.lock()
        defer { condition.unlock() }

        guard !didRequestStop, process.isRunning else {
            throw CodexAppServerError.noResponse
        }

        do {
            try input.write(contentsOf: data)
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.noResponse
        }
    }
}

private enum CodexStdoutReader {
    static func run(
        output: FileHandle,
        maximumResponseBytes: Int,
        expectedResponse: ExpectedCodexResponse,
        continuation: AsyncThrowingStream<CodexAppServerEnvelope, Error>.Continuation
    ) async {
        var line = Data()

        do {
            for try await byte in output.bytes {
                try Task.checkCancellation()

                if byte == 0x0A {
                    try yieldResponse(
                        from: line,
                        expectedResponse: expectedResponse,
                        continuation: continuation
                    )
                    line.removeAll(keepingCapacity: false)
                    continue
                }

                guard line.count < maximumResponseBytes else {
                    throw CodexAppServerError.responseTooLarge
                }
                line.append(byte)
            }

            try yieldResponse(
                from: line,
                expectedResponse: expectedResponse,
                continuation: continuation
            )
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch let error as CodexAppServerError {
            continuation.finish(throwing: error)
        } catch {
            continuation.finish(throwing: CodexAppServerError.noResponse)
        }
    }

    private static func yieldResponse(
        from data: Data,
        expectedResponse: ExpectedCodexResponse,
        continuation: AsyncThrowingStream<CodexAppServerEnvelope, Error>.Continuation
    ) throws {
        guard !data.isEmpty else { return }

        let header: CodexResponseHeader
        do {
            header = try JSONDecoder().decode(CodexResponseHeader.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse
        }

        guard let id = header.id, let method = expectedResponse.consume(id) else { return }
        let result: Result<CodexTransportResult, CodexAppServerError>
        do {
            switch method {
            case .rateLimits:
                result = .success(.rateLimits(try decodeResult(CodexRateLimitsResult.self, from: data)))
            case .accountUsage:
                result = .success(.accountUsage(try decodeResult(CodexAccountUsageTransportResult.self, from: data)))
            }
        } catch let error as CodexAppServerError {
            result = .failure(error)
        } catch {
            result = .failure(.invalidResponse)
        }
        continuation.yield(CodexAppServerEnvelope(id: id, result: result))
    }

    private static func decodeResult<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let envelope = try JSONDecoder().decode(CodexResponsePayload<Value>.self, from: data)
        if let error = envelope.error { throw CodexAppServerError.serverError(code: error.code) }
        guard let result = envelope.result else { throw CodexAppServerError.invalidResponse }
        return result
    }
}
