import Foundation

enum ClaudeProviderError: Error, Equatable, Sendable {
    case noRateLimits
    case sourceUnavailable
}

extension ClaudeProviderError: ProviderStatusProvidingError {
    var providerStatus: ProviderStatus {
        switch self {
        case .noRateLimits:
            .failed(.usageUnavailable)
        case .sourceUnavailable:
            .failed(.refreshFailed)
        }
    }
}

struct ClaudeProvider: UsageProvider, Sendable {
    let id = ProviderID.claude

    private let reader: any ClaudeUsageSnapshotReading
    private let locale: Locale
    private let now: @Sendable () -> Date

    init(
        reader: any ClaudeUsageSnapshotReading = ClaudeSnapshotReader(),
        locale: Locale = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.locale = locale
        self.now = now
    }

    func runtimeDiagnostic() async -> ProviderRuntimeDiagnostic {
        ProviderRuntimeDiagnostic(
            hostApplication: nil,
            runtimeSource: .localSnapshot,
            runtimeDetected: nil,
            compatibilityStatus: .unverified,
            appServerState: .notApplicable,
            lastFailureCategory: nil
        )
    }

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        let document: ClaudeUsageSnapshotDocument
        do {
            document = try await reader.readSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as any ProviderStatusProvidingError {
            throw error
        } catch {
            throw ClaudeProviderError.sourceUnavailable
        }

        guard document.schemaVersion == ClaudeSnapshotReader.supportedSchemaVersion else {
            throw ClaudeSnapshotReaderError.unsupportedSchema(version: document.schemaVersion)
        }
        let sample = try ClaudeQuotaValidation.sample(
            fiveHour: document.rateLimits.fiveHour, sevenDay: document.rateLimits.sevenDay,
            observedAt: document.capturedAt, version: document.claudeCodeVersion, now: now()
        )
        var windows: [UsageWindow] = []

        if let fiveHour = makeUsageWindow(
            id: "claude.five-hour",
            label: AppLocalization.string("5-hour window", locale: locale),
            duration: .seconds(18_000),
            source: sample.fiveHour
        ) {
            windows.append(fiveHour)
        }

        if let sevenDay = makeUsageWindow(
            id: "claude.seven-day",
            label: AppLocalization.string("7-day window", locale: locale),
            duration: .seconds(604_800),
            source: sample.sevenDay
        ) {
            windows.append(sevenDay)
        }

        guard !windows.isEmpty else {
            throw ClaudeProviderError.noRateLimits
        }

        return ProviderUsageSnapshot(
            providerID: .claude,
            windows: windows,
            capturedAt: document.capturedAt,
            source: UsageSource(
                kind: .claudeStatusLineSnapshot,
                label: "Claude Code status-line snapshot",
                documentationURL: URL(string: "https://code.claude.com/docs/en/statusline")
            ),
            validity: sample.isStale(at: now()) ? .stale : .unexpired
        )
    }

    private func makeUsageWindow(
        id: String,
        label: String,
        duration: Duration,
        source: ClaudeValidatedQuotaWindow?
    ) -> UsageWindow? {
        guard let source else { return nil }

        let usedPercentage = source.usedPercentage
        let resetAt = source.reset.date

        guard usedPercentage != nil || resetAt != nil else { return nil }

        return UsageWindow(
            id: id,
            label: label,
            usedPercentage: usedPercentage,
            resetAt: resetAt,
            duration: duration
        )
    }
}
