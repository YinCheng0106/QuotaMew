import Foundation
import XCTest
@testable import QuotaMew

final class ClaudeDiagnosticContractTests: XCTestCase {
    private func candidate(_ kind: ClaudeInstallationKind) -> ClaudeInstallationCandidate {
        .init(executableURL: URL(fileURLWithPath: "/synthetic-private/\(kind)/claude"), kind: kind)
    }

    func testFixedBoundedAuthRequestAndFakeRunner() async throws {
        let request = ClaudeAuthDiagnosticRequest(candidate: candidate(.native))
        XCTAssertEqual(request.arguments, ["auth", "status", "--json"])
        XCTAssertEqual(request.maximumStdoutBytes, 16_384)
        XCTAssertEqual(request.maximumStderrBytes, 4_096)
        XCTAssertEqual(request.timeout, .seconds(10))
        XCTAssertTrue(request.closesStandardInput)
        let state = try await FakeAuthRunner().authStatus(request)
        XCTAssertEqual(state, .notAuthenticated)
        XCTAssertFalse(String(reflecting: request).contains("synthetic-private"))
        XCTAssertFalse(String(reflecting: state).contains("fake@example.invalid"))
    }

    func testAuthAllowlistExitEvidenceAndPrivacy() throws {
        for (loggedIn, exitCode, expected) in [(true, Int32(0), ClaudeBroadAuthState.authenticated),
                                               (false, Int32(1), .notAuthenticated)] {
            let raw = Data("{\"loggedIn\":\(loggedIn),\"email\":\"fake@example.invalid\",\"token\":\"synthetic-secret\"}".utf8)
            let result = try ClaudeAuthStatusParser.parse(raw, exitCode: exitCode, stderrByteCount: 12)
            XCTAssertEqual(result, expected)
            XCTAssertFalse(String(reflecting: result).contains("synthetic-secret"))
        }
        for json in [#"{"loggedIn":"synthetic-secret"}"#, #"{"loggedIn":1}"#, "synthetic-secret"] {
            XCTAssertThrowsError(try ClaudeAuthStatusParser.parse(Data(json.utf8), exitCode: 1, stderrByteCount: 0)) {
                XCTAssertFalse(String(reflecting: $0).contains("synthetic-secret"))
            }
        }
        for exit in [Int32(0), 2, -1] {
            XCTAssertThrowsError(try ClaudeAuthStatusParser.parse(Data(#"{"loggedIn":false}"#.utf8), exitCode: exit, stderrByteCount: 0))
        }
        XCTAssertThrowsError(try ClaudeAuthStatusParser.parse(Data(repeating: 32, count: 16_385), exitCode: 1, stderrByteCount: 0))
        XCTAssertThrowsError(try ClaudeAuthStatusParser.parse(Data(#"{"loggedIn":false}"#.utf8), exitCode: 1, stderrByteCount: 4_097))
    }

    func testLocatorDoesNotMistakeFirstPathHitForInstallationStatus() async throws {
        let locator = ClaudeInstallationLocator(probe: FakeInstallationProbe(native: .usable(ClaudeCodeVersion("2.1.246")!), npm: .unusable))
        let selection = try await locator.select(from: [candidate(.npm), candidate(.native)])
        XCTAssertEqual(selection, .selected(candidate(.native), ClaudeCodeVersion("2.1.246")!))
        XCTAssertFalse(String(reflecting: selection).contains("synthetic-private"))
    }

    func testLocatorFailuresHaveOnlyPreciseEvidence() async throws {
        let cases: [(ClaudeInstallationProbeResult, ProviderRuntimeUnavailableReason)] = [
            (.missing, .notInstalled), (.unusable, .providerError), (.permissionDenied, .permissionDenied),
            (.usable(ClaudeCodeVersion("1.0.43")!), .unsupportedVersion)
        ]
        for (result, reason) in cases {
            let locator = ClaudeInstallationLocator(probe: FakeInstallationProbe(native: result, npm: result))
            let selection = try await locator.select(from: [candidate(.native), candidate(.npm)])
            XCTAssertEqual(selection, .unavailable(reason))
        }
        let future = ClaudeInstallationLocator(probe: FakeInstallationProbe(native: .unusable, npm: .usable(ClaudeCodeVersion("3.0.0")!)))
        let selection = try await future.select(from: [candidate(.native), candidate(.npm)])
        XCTAssertEqual(selection, .selected(candidate(.npm), ClaudeCodeVersion("3.0.0")!))
    }

    func testLocatorCancellationIsPropagated() async {
        let locator = ClaudeInstallationLocator(probe: CancelledInstallationProbe())
        do {
            _ = try await locator.select(from: [candidate(.native)])
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAuthTimeoutCancellationAndUnknownRunnerFailureStayTyped() async {
        for error in [ClaudeAuthDiagnosticError.timeout as any Error,
                      NSError(domain: "synthetic-secret-stderr", code: 2), CancellationError()] {
            let diagnostic = ClaudeAuthDiagnostic(runner: FailingAuthRunner(error: error))
            do { _ = try await diagnostic.inspect(candidate(.native)); XCTFail("Expected failure") }
            catch let caught {
                if error is CancellationError { XCTAssertTrue(caught is CancellationError) }
                else if error is ClaudeAuthDiagnosticError { XCTAssertEqual(caught as? ClaudeAuthDiagnosticError, .timeout) }
                else { XCTAssertEqual(caught as? ClaudeAuthDiagnosticError, .providerError) }
                XCTAssertFalse(String(reflecting: caught).contains("synthetic-secret-stderr"))
            }
        }
    }
}

private struct FakeAuthRunner: ClaudeAuthDiagnosticRunning {
    func authStatus(_ request: ClaudeAuthDiagnosticRequest) async throws -> ClaudeBroadAuthState {
        try Task.checkCancellation()
        return try ClaudeAuthStatusParser.parse(Data(#"{"loggedIn":false,"email":"fake@example.invalid"}"#.utf8), exitCode: 1, stderrByteCount: 0)
    }
}

private struct FailingAuthRunner: ClaudeAuthDiagnosticRunning {
    let error: any Error
    func authStatus(_ request: ClaudeAuthDiagnosticRequest) async throws -> ClaudeBroadAuthState { throw error }
}

private struct FakeInstallationProbe: ClaudeInstallationProbing {
    let native: ClaudeInstallationProbeResult
    let npm: ClaudeInstallationProbeResult
    func inspect(_ candidate: ClaudeInstallationCandidate) async throws -> ClaudeInstallationProbeResult {
        candidate.kind == .native ? native : npm
    }
}

private struct CancelledInstallationProbe: ClaudeInstallationProbing {
    func inspect(_ candidate: ClaudeInstallationCandidate) async throws -> ClaudeInstallationProbeResult {
        throw CancellationError()
    }
}
