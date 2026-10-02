protocol TokenActivitySource: Sendable {
    var id: ProviderID { get }
    func fetchActivity() async throws -> ActivityFetchResult
}
