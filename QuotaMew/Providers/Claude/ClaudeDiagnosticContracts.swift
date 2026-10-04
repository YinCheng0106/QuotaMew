import Foundation

enum ClaudeInstallationKind: Equatable, Sendable {
    case native, npm
}

struct ClaudeInstallationCandidate: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let executableURL: URL
    let kind: ClaudeInstallationKind
    var description: String { "Claude installation candidate (\(kind))" }
    var debugDescription: String { description }
}

enum ClaudeInstallationProbeResult: Equatable, Sendable {
    case missing
    case usable(ClaudeCodeVersion)
    case unusable
    case permissionDenied
}

protocol ClaudeInstallationProbing: Sendable {
    // A future implementation may probe only the supplied candidates, with bounded one-shot
    // --version argv. No login shell, PATH mutation, arbitrary scan or raw error propagation.
    func inspect(_ candidate: ClaudeInstallationCandidate) async throws -> ClaudeInstallationProbeResult
}

enum ClaudeInstallationSelection: Equatable, Sendable {
    case selected(ClaudeInstallationCandidate, ClaudeCodeVersion)
    case unavailable(ProviderRuntimeUnavailableReason)
}

struct ClaudeInstallationLocator: Sendable {
    let probe: any ClaudeInstallationProbing

    // Foundation only: candidate inventory is supplied explicitly; no production filesystem discovery.
    func select(from candidates: [ClaudeInstallationCandidate]) async throws -> ClaudeInstallationSelection {
        guard !candidates.isEmpty, candidates.count <= 8,
              candidates.allSatisfy({ $0.executableURL.isFileURL && $0.executableURL.path.hasPrefix("/") }) else {
            return .unavailable(.awaitingSource)
        }
        var allMissing = true
        var sawPermissionDenied = false
        var sawOldVersion = false
        var sawUnusable = false
        // Prefer a usable native install, but evaluate npm if native cannot run.
        let ordered = candidates.filter { $0.kind == .native } + candidates.filter { $0.kind == .npm }
        for candidate in ordered {
            try Task.checkCancellation()
            let result: ClaudeInstallationProbeResult
            do {
                result = try await probe.inspect(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = .unusable
            }
            try Task.checkCancellation()
            switch result {
            case .missing: continue
            case .permissionDenied: allMissing = false; sawPermissionDenied = true
            case .unusable: allMissing = false; sawUnusable = true
            case .usable(let version):
                allMissing = false
                if ClaudeVersionCompatibility.evaluate(version.canonicalString).permitsQuotaParsing {
                    return .selected(candidate, version)
                }
                sawOldVersion = true
            }
        }
        if allMissing { return .unavailable(.notInstalled) }
        if sawPermissionDenied { return .unavailable(.permissionDenied) }
        if sawOldVersion && !sawUnusable { return .unavailable(.unsupportedVersion) }
        return .unavailable(.providerError)
    }
}

struct ClaudeAuthDiagnosticRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let candidate: ClaudeInstallationCandidate
    let arguments = ["auth", "status", "--json"]
    let maximumStdoutBytes = 16_384
    let maximumStderrBytes = 4_096
    let timeout: Duration = .seconds(10)
    let closesStandardInput = true
    var description: String { "Claude auth status diagnostic" }
    var debugDescription: String { description }
}

enum ClaudeAuthDiagnosticError: Error, Equatable, Sendable {
    case invalidResponse, outputTooLarge, timeout, providerError
}

enum ClaudeBroadAuthState: Equatable, Sendable {
    case authenticated, notAuthenticated

    var runtimeAvailability: ProviderRuntimeAvailability {
        switch self {
        case .authenticated: .available
        case .notAuthenticated: .unavailable(.notAuthenticated)
        }
    }
}

protocol ClaudeAuthDiagnosticRunning: Sendable {
    // Implementation obligation for M2/M3: execute candidate URL + fixed argv directly,
    // enforce both output bounds + timeout, close stdin, cancel/terminate/reap and close
    // every pipe on every exit. Return allowlisted state only; never raw stdout/stderr.
    // This milestone provides no production runner and never calls it during quota refresh.
    func authStatus(_ request: ClaudeAuthDiagnosticRequest) async throws -> ClaudeBroadAuthState
}

struct ClaudeAuthDiagnostic: Sendable {
    let runner: any ClaudeAuthDiagnosticRunning

    func inspect(_ candidate: ClaudeInstallationCandidate) async throws -> ClaudeBroadAuthState {
        try Task.checkCancellation()
        do {
            let state = try await runner.authStatus(.init(candidate: candidate))
            try Task.checkCancellation()
            return state
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeAuthDiagnosticError {
            throw error
        } catch {
            throw ClaudeAuthDiagnosticError.providerError
        }
    }
}

enum ClaudeAuthStatusParser {
    private struct Response: Decodable { let loggedIn: Bool }

    static func parse(_ stdout: Data, exitCode: Int32, stderrByteCount: Int) throws -> ClaudeBroadAuthState {
        guard stdout.count <= 16_384, (0...4_096).contains(stderrByteCount) else {
            throw ClaudeAuthDiagnosticError.outputTooLarge
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: stdout)
        } catch {
            throw ClaudeAuthDiagnosticError.invalidResponse
        }
        switch (response.loggedIn, exitCode) {
        case (true, 0): return .authenticated
        case (false, 1): return .notAuthenticated
        default: throw ClaudeAuthDiagnosticError.providerError
        }
    }
}
