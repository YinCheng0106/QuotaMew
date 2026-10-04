import Foundation
import Darwin

enum ClaudeBridgeCaptureResult: Equatable, Sendable {
    case captured(ClaudeSnapshotGeneration)
    case noRateLimits, unverifiedVersion, unsupportedVersion, invalidQuota
    case inputTooLarge, inputTimedOut, inputFailed, writeFailed, cancelled

    var exitCode: Int32 {
        switch self {
        case .captured, .noRateLimits: 0
        case .unverifiedVersion, .unsupportedVersion: 2
        case .invalidQuota, .inputTooLarge, .inputTimedOut, .inputFailed: 3
        case .writeFailed: 4
        case .cancelled: 130
        }
    }
}

struct ClaudePassiveBridge: Sendable {
    let writer: ClaudeSnapshotWriter

    func capture(_ originalBytes: Data, clock: () -> Date = Date.init) -> ClaudeBridgeCaptureResult {
        do {
            try Task.checkCancellation()
            // Validate first, then timestamp this successful local receipt. The second pure
            // projection establishes the exact observedAt, never an upstream fetch time.
            let received = clock()
            let validated = try ClaudeStatusLineParser.parse(originalBytes, observedAt: received, now: received)
            guard [validated.fiveHour, validated.sevenDay].compactMap({ $0 }).contains(where: {
                $0.usedPercentage != nil || $0.reset.date != nil
            }) else { return .noRateLimits }
            let observed = clock()
            let sample = try ClaudeQuotaValidation.sample(
                fiveHour: validated.snapshotDocument().rateLimits.fiveHour,
                sevenDay: validated.snapshotDocument().rateLimits.sevenDay,
                observedAt: observed, version: validated.version.canonicalString, now: observed)
            return .captured(try writer.write(sample))
        } catch is CancellationError { return .cancelled }
        catch let error as ClaudeContractError {
            switch error {
            case .inputTooLarge: return .inputTooLarge
            case .unverifiedVersion: return .unverifiedVersion
            case .unsupportedVersion: return .unsupportedVersion
            default: return .invalidQuota
            }
        } catch { return .writeFailed }
    }
}

enum ClaudeBridgeInputError: Error, Equatable, Sendable { case oversized, timedOut, unreadable }

enum ClaudeBridgeInput {
    // Transport has headroom for unrelated official status-line metadata. Capture still
    // enforces the shared M1 16 KiB parser limit; 16...64 KiB events can render unchanged.
    static let maximumBytes = 65_536
    static let timeout: TimeInterval = 2

    static func read(descriptor: Int32, duration: TimeInterval = timeout) throws -> Data {
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw ClaudeBridgeInputError.unreadable
        }
        defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(duration, 0), timeout)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ClaudeBridgeInputError.timedOut }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(min(remaining * 1_000, 100)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw ClaudeBridgeInputError.unreadable }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, maximumBytes + 1 - data.count))
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw ClaudeBridgeInputError.unreadable }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= maximumBytes else { throw ClaudeBridgeInputError.oversized }
        }
    }
}

// The command is caller-owned configuration. It never comes from provider JSON.
struct ClaudeBridgeDownstreamCommand: Sendable {
    let executable: URL
    let arguments: [String]

    static func userAuthoredShell(_ opaqueCommand: String) -> Self {
        .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", opaqueCommand])
    }
}

enum ClaudeBridgeDownstreamResult: Equatable, Sendable {
    case exited(Int32), launchFailed, timedOut, outputTooLarge, ioFailed, cancelled
    var exitCode: Int32 {
        switch self {
        case .exited(let code): code
        case .launchFailed: 127
        case .timedOut: 124
        case .outputTooLarge, .ioFailed: 125
        case .cancelled: 130
        }
    }
}

struct ClaudeBridgeExecutionResult: Equatable, Sendable {
    let capture: ClaudeBridgeCaptureResult
    let downstream: ClaudeBridgeDownstreamResult?
    var exitCode: Int32 { downstream?.exitCode ?? capture.exitCode }
}
