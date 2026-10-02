import Foundation

protocol CodexAccountUsageReading: Sendable {
    func readAccountUsageTransport() async throws -> CodexAccountUsageTransportResult
}

extension CodexAppServerClient: CodexAccountUsageReading {}

/// Requires an injected reader; never creates a client or starts a quota refresh.
struct CodexTokenActivitySource: TokenActivitySource {
    let id = ProviderID.codex
    private let reader: any CodexAccountUsageReading
    private let now: @Sendable () -> Date

    init(reader: any CodexAccountUsageReading, now: @escaping @Sendable () -> Date = Date.init) {
        self.reader = reader
        self.now = now
    }

    func fetchActivity() async throws -> ActivityFetchResult {
        do {
            try Task.checkCancellation()
            let response = try await reader.readAccountUsageTransport()
            try Task.checkCancellation()
            guard let daily = response.dailyUsageBuckets else {
                return .noDailyBuckets(source: .codexAccountUsage, capturedAt: now(),
                    reason: response.hasDailyUsageBuckets ? .nullCollection : .missingCollection)
            }
            guard daily.count <= ProviderActivitySnapshot.maximumBucketCount else {
                throw ActivityFetchError.limitExceeded
            }
            guard !daily.isEmpty else {
                return .noDailyBuckets(source: .codexAccountUsage, capturedAt: now(), reason: .emptyCollection)
            }
            let buckets = try daily.map {
                try ActivityBucket(sourceDate: ProviderCalendarDate($0.startDate), reportedTokens: $0.tokens)
            }
            // Capture only after all core data (including duplicate policy) passes validation.
            return .snapshot(try ProviderActivitySnapshot(providerID: id, buckets: buckets,
                capturedAt: now(), source: .codexAccountUsage))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ActivityFetchError {
            throw error
        } catch let error as CodexAppServerError {
            switch error {
            case .serverError(code: -32601): return .unsupported
            case .invalidResponse: throw ActivityFetchError.invalidData
            case .responseTooLarge, .requestCapacityExceeded: throw ActivityFetchError.limitExceeded
            case .timeout: throw ActivityFetchError.timedOut
            case .executableNotFound: throw ActivityFetchError.providerUnavailable
            case .launchFailed, .noResponse, .serverError: throw ActivityFetchError.fetchFailed
            }
        } catch is DecodingError {
            throw ActivityFetchError.invalidData
        } catch {
            throw ActivityFetchError.fetchFailed
        }
    }
}
