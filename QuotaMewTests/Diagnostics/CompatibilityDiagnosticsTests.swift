import Foundation
import XCTest
@testable import QuotaMew

final class CompatibilityDiagnosticsTests: XCTestCase {
    private let attemptDate = Date(timeIntervalSince1970: 2_000_000_123)
    private let successDate = Date(timeIntervalSince1970: 2_000_000_000)

    func testHealthyCodexDiagnosticsExposeCurrentAllowlistedState() throws {
        let diagnostics = makeDiagnostics(
            state: availableState(),
            runtime: healthyCodexRuntime()
        )
        let codex = try XCTUnwrap(diagnostics.providers.first)

        XCTAssertEqual(codex.providerID, .codex)
        XCTAssertTrue(codex.isEnabled)
        XCTAssertEqual(codex.availability, .available)
        XCTAssertEqual(codex.runtimeSource, .chatGPTApplication)
        XCTAssertEqual(codex.runtimeDetected, true)
        XCTAssertEqual(codex.compatibilityStatus, .compatible)
        XCTAssertEqual(codex.appServerState, .connected)
        XCTAssertEqual(codex.refreshOutcome, .successful)
        XCTAssertEqual(codex.lastRefreshAttemptAt, attemptDate)
        XCTAssertEqual(codex.lastSuccessfulRefreshAt, successDate)
        XCTAssertTrue(codex.usageMetadataAvailable)
        XCTAssertTrue(codex.resetMetadataAvailable)
        XCTAssertNil(codex.lastFailureCategory)
    }

    func testRuntimeNotDetectedUsesSanitizedCategory() throws {
        let runtime = ProviderRuntimeDiagnostic(
            hostApplication: DiagnosticHostApplicationState(
                application: .chatGPT,
                isDetected: true,
                version: DiagnosticVersion("26.818.1")
            ),
            runtimeSource: .notDetected,
            runtimeDetected: false,
            compatibilityStatus: .unavailable,
            appServerState: .notStarted,
            lastFailureCategory: .runtimeNotDetected
        )
        let diagnostics = makeDiagnostics(
            state: ProviderState(providerID: .codex, status: .notInstalled, snapshot: nil),
            runtime: runtime
        )

        XCTAssertEqual(diagnostics.providers.first?.runtimeDetected, false)
        XCTAssertEqual(
            diagnostics.providers.first?.lastFailureCategory,
            .runtimeNotDetected
        )
        let report = CompatibilityDiagnosticsReport.make(from: diagnostics)
        XCTAssertTrue(report.contains("Availability: Runtime unavailable"))
        XCTAssertTrue(report.contains("ChatGPT.app Installed: Yes"))
        XCTAssertTrue(report.contains("Runtime Detected: No"))
    }

    func testProviderDisabledIsExplicitAndKeepsRuntimeSnapshotCurrent() throws {
        let diagnostics = makeDiagnostics(
            state: ProviderState(providerID: .codex, status: .disabled, snapshot: nil),
            runtime: healthyCodexRuntime(),
            isEnabled: false
        )
        let codex = try XCTUnwrap(diagnostics.providers.first)

        XCTAssertFalse(codex.isEnabled)
        XCTAssertEqual(codex.availability, .disabled)
        XCTAssertEqual(codex.refreshOutcome, .disabled)
        XCTAssertEqual(codex.lastFailureCategory, .providerDisabled)
        XCTAssertEqual(codex.runtimeSource, .chatGPTApplication)
    }

    func testAppServerConnectionFailureRemainsBoundedAndSanitized() throws {
        let runtime = ProviderRuntimeDiagnostic(
            hostApplication: nil,
            runtimeSource: .standaloneCodex,
            runtimeDetected: true,
            compatibilityStatus: .unverified,
            appServerState: .disconnected,
            lastFailureCategory: .appServerConnectionFailed
        )
        let diagnostics = makeDiagnostics(
            state: ProviderState(
                providerID: .codex,
                status: .failed(.refreshFailed),
                snapshot: nil
            ),
            runtime: runtime
        )
        let codex = try XCTUnwrap(diagnostics.providers.first)

        XCTAssertEqual(codex.appServerState, .disconnected)
        XCTAssertEqual(codex.refreshOutcome, .failed)
        XCTAssertEqual(codex.lastFailureCategory, .appServerConnectionFailed)
    }

    func testUsageUnavailableDoesNotFabricateUsageOrResetMetadata() throws {
        let diagnostics = makeDiagnostics(
            state: ProviderState(
                providerID: .codex,
                status: .failed(.usageUnavailable),
                snapshot: nil
            ),
            runtime: healthyCodexRuntime()
        )
        let codex = try XCTUnwrap(diagnostics.providers.first)

        XCTAssertFalse(codex.usageMetadataAvailable)
        XCTAssertFalse(codex.resetMetadataAvailable)
        XCTAssertEqual(codex.lastFailureCategory, .usageUnavailable)
    }

    func testLastRefreshFailureKeepsLastSuccessfulTimestampWithoutClaimingSuccess() throws {
        let failedState = ProviderState(
            providerID: .codex,
            status: .failed(.refreshFailed),
            snapshot: availableState().snapshot
        )
        let diagnostics = makeDiagnostics(
            state: failedState,
            runtime: ProviderRuntimeDiagnostic(
                hostApplication: nil,
                runtimeSource: .standaloneCodex,
                runtimeDetected: true,
                compatibilityStatus: .unverified,
                appServerState: .disconnected,
                lastFailureCategory: .rpcUnavailable
            )
        )
        let codex = try XCTUnwrap(diagnostics.providers.first)

        XCTAssertEqual(codex.refreshOutcome, .failed)
        XCTAssertEqual(codex.lastSuccessfulRefreshAt, successDate)
        XCTAssertEqual(codex.lastFailureCategory, .rpcUnavailable)
        XCTAssertTrue(codex.usageMetadataAvailable)
    }

    func testEnglishReportContainsExpectedSanitizedFieldsWithoutQuotaPercentages() {
        let report = CompatibilityDiagnosticsReport.make(
            from: makeDiagnostics(state: availableState(), runtime: healthyCodexRuntime())
        )

        XCTAssertTrue(report.contains("QuotaMew Diagnostics"))
        XCTAssertTrue(report.contains("Version: 0.1.0"))
        XCTAssertTrue(report.contains("Architecture: arm64"))
        XCTAssertTrue(report.contains("Runtime Source: ChatGPT.app"))
        XCTAssertTrue(report.contains("App Server: Connected"))
        XCTAssertTrue(report.contains("Usage Available: Yes"))
        XCTAssertTrue(report.contains("Last Refresh: Successful"))
        XCTAssertFalse(report.contains("42%"))
    }

    func testReportDoesNotContainSensitiveFixtureValuesOrRawProviderContent() {
        let sensitiveValues = [
            "/Users/alice/Private/ChatGPT.app/Contents/Resources/codex",
            "sk-test-credential-123",
            "alice@example.com",
            "secret-project-name",
            "prompt: refactor private source code",
            "session-content-123",
            "{\"access_token\":\"oauth-secret\"}",
        ]
        let snapshot = ProviderUsageSnapshot(
            providerID: .codex,
            windows: [
                UsageWindow(
                    id: sensitiveValues[3],
                    label: sensitiveValues[4],
                    usedPercentage: 42,
                    resetAt: successDate.addingTimeInterval(3_600),
                    duration: .seconds(18_000)
                )
            ],
            capturedAt: successDate,
            source: UsageSource(
                kind: .codexAppServer,
                label: sensitiveValues.joined(separator: " "),
                documentationURL: nil
            )
        )
        let diagnostics = makeDiagnostics(
            state: ProviderState(providerID: .codex, status: .available, snapshot: snapshot),
            runtime: healthyCodexRuntime(),
            environment: CompatibilityDiagnosticEnvironment(
                appVersion: DiagnosticVersion(sensitiveValues[0]),
                buildNumber: DiagnosticVersion(sensitiveValues[1]),
                macOSVersion: DiagnosticVersion("26.0.0"),
                architecture: .arm64
            )
        )
        let report = CompatibilityDiagnosticsReport.make(from: diagnostics)

        for sensitiveValue in sensitiveValues {
            XCTAssertFalse(report.contains(sensitiveValue))
        }
        XCTAssertNil(DiagnosticVersion(sensitiveValues[0]))
        XCTAssertNil(DiagnosticVersion(sensitiveValues[1]))
    }

    func testProviderIndependentContractRendersMultipleProvidersWithoutUIBranches() {
        let codexState = availableState()
        let claudeState = ProviderState(
            providerID: .claude,
            status: .notConfigured,
            snapshot: nil
        )
        let diagnostics = CompatibilityDiagnosticsSnapshot(
            environment: environment(),
            providerStates: [codexState, claudeState],
            providerContexts: [
                ProviderDiagnosticContext(
                    providerID: .codex,
                    isEnabled: true,
                    runtime: healthyCodexRuntime()
                ),
                ProviderDiagnosticContext(
                    providerID: .claude,
                    isEnabled: true,
                    runtime: ProviderRuntimeDiagnostic(
                        hostApplication: nil,
                        runtimeSource: .localSnapshot,
                        runtimeDetected: nil,
                        compatibilityStatus: .unverified,
                        appServerState: .notApplicable,
                        lastFailureCategory: nil
                    )
                ),
            ],
            lastRefreshAttemptAt: attemptDate
        )
        let report = CompatibilityDiagnosticsReport.make(from: diagnostics)

        XCTAssertEqual(diagnostics.providers.map(\.providerID), [.codex, .claude])
        XCTAssertTrue(report.contains("Codex"))
        XCTAssertTrue(report.contains("Claude Code"))
        XCTAssertTrue(report.contains("Runtime Source: Local snapshot"))
        XCTAssertTrue(report.contains("Last Failure: notConfigured"))
    }

    func testSnapshotDeduplicatesProvidersAndContainsNoDiagnosticHistory() {
        let state = availableState()
        let diagnostics = CompatibilityDiagnosticsSnapshot(
            environment: environment(),
            providerStates: [state, state, state],
            providerContexts: [
                ProviderDiagnosticContext(
                    providerID: .codex,
                    isEnabled: true,
                    runtime: healthyCodexRuntime()
                ),
                ProviderDiagnosticContext(
                    providerID: .codex,
                    isEnabled: false,
                    runtime: .unknown
                ),
            ],
            lastRefreshAttemptAt: attemptDate
        )
        let report = CompatibilityDiagnosticsReport.make(from: diagnostics)

        XCTAssertEqual(diagnostics.providers.count, 1)
        XCTAssertEqual(report.components(separatedBy: "\nCodex\n").count - 1, 1)
        XCTAssertFalse(report.localizedCaseInsensitiveContains("history"))
    }

    private func makeDiagnostics(
        state: ProviderState,
        runtime: ProviderRuntimeDiagnostic,
        isEnabled: Bool = true,
        environment: CompatibilityDiagnosticEnvironment? = nil
    ) -> CompatibilityDiagnosticsSnapshot {
        CompatibilityDiagnosticsSnapshot(
            environment: environment ?? self.environment(),
            providerStates: [state],
            providerContexts: [
                ProviderDiagnosticContext(
                    providerID: state.providerID,
                    isEnabled: isEnabled,
                    runtime: runtime
                )
            ],
            lastRefreshAttemptAt: attemptDate
        )
    }

    private func environment() -> CompatibilityDiagnosticEnvironment {
        CompatibilityDiagnosticEnvironment(
            appVersion: DiagnosticVersion("0.1.0"),
            buildNumber: DiagnosticVersion("1"),
            macOSVersion: DiagnosticVersion("26.0.0"),
            architecture: .arm64
        )
    }

    private func availableState() -> ProviderState {
        ProviderState(
            providerID: .codex,
            status: .available,
            snapshot: ProviderUsageSnapshot(
                providerID: .codex,
                windows: [
                    UsageWindow(
                        id: "codex.primary",
                        label: "Primary window",
                        usedPercentage: 42,
                        resetAt: successDate.addingTimeInterval(3_600),
                        duration: .seconds(18_000)
                    )
                ],
                capturedAt: successDate,
                source: UsageSource(
                    kind: .codexAppServer,
                    label: "Codex app-server",
                    documentationURL: nil
                )
            )
        )
    }

    private func healthyCodexRuntime() -> ProviderRuntimeDiagnostic {
        ProviderRuntimeDiagnostic(
            hostApplication: DiagnosticHostApplicationState(
                application: .chatGPT,
                isDetected: true,
                version: DiagnosticVersion("26.818.1")
            ),
            runtimeSource: .chatGPTApplication,
            runtimeDetected: true,
            compatibilityStatus: .compatible,
            appServerState: .connected,
            lastFailureCategory: nil
        )
    }
}
