import Foundation

struct QuotaResetWindowIdentity: Codable, Equatable, Hashable, Sendable {
    let providerID: ProviderID
    let windowID: String
    let cycleIdentifier: String
}

struct DetectedQuotaReset: Equatable, Sendable {
    let identity: QuotaResetWindowIdentity
    let windowLabel: String
    let windowDuration: Duration?
    let detectedAt: Date
    let resetAt: Date
}

struct LocalResetDetectionState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var entries: [Entry] = []

    struct Entry: Codable, Equatable, Sendable {
        let providerID: ProviderID
        let windowID: String
        var cycleIdentifier: String
        var providerCycleIdentifier: String?
        var resetMinute: Int64
        var capturedAtSecond: Int64
        var usedPercentage: Double?
        var lastNotifiedCycleIdentifier: String?

        var key: Key {
            Key(providerID: providerID, windowID: windowID)
        }
    }

    struct Key: Hashable, Sendable {
        let providerID: ProviderID
        let windowID: String
    }
}

struct LocalResetDetectionEvaluation: Equatable, Sendable {
    let state: LocalResetDetectionState
    let resets: [DetectedQuotaReset]
}

struct LocalResetDetector: Equatable, Sendable {
    static let standard = LocalResetDetector(
        maximumSnapshotAge: 15 * 60,
        maximumFutureCaptureSkew: 5 * 60,
        resetTimestampTolerance: 2 * 60,
        maximumObservationGap: 2 * 60 * 60,
        substantialUsageDrop: 25,
        minimumResetAdvanceWithoutDuration: 30 * 60,
        minimumResetAdvanceFraction: 0.5,
        maximumPersistedEntries: 32,
        maximumIdentifierBytes: 256
    )

    let maximumSnapshotAge: TimeInterval
    let maximumFutureCaptureSkew: TimeInterval
    let resetTimestampTolerance: TimeInterval
    let maximumObservationGap: TimeInterval
    let substantialUsageDrop: Double
    let minimumResetAdvanceWithoutDuration: TimeInterval
    let minimumResetAdvanceFraction: Double
    let maximumPersistedEntries: Int
    let maximumIdentifierBytes: Int

    func evaluate(
        _ providerStates: [ProviderState],
        state originalState: LocalResetDetectionState,
        now: Date
    ) -> LocalResetDetectionEvaluation {
        var state = validState(from: originalState)
        var resets: [DetectedQuotaReset] = []
        var evaluatedKeys: Set<LocalResetDetectionState.Key> = []
        state.entries.removeAll { $0.providerID.capabilities.support(for: .resetNotifications) != .supported }

        for providerState in providerStates {
            guard providerState.providerID.capabilities.support(for: .resetNotifications) == .supported else { continue }
            guard providerState.status == .available else { continue }
            guard
                let snapshot = providerState.snapshot,
                snapshot.providerID == providerState.providerID,
                snapshot.source.kind != .mock,
                isFresh(snapshot, now: now),
                let capturedAtSecond = normalizedSecond(snapshot.capturedAt)
            else {
                continue
            }

            for window in snapshot.windows {
                guard isBoundedIdentifier(window.id) else { continue }
                let key = LocalResetDetectionState.Key(
                    providerID: providerState.providerID,
                    windowID: window.id
                )
                guard evaluatedKeys.insert(key).inserted else { continue }
                guard
                    let resetAt = window.resetAt,
                    resetAt.timeIntervalSince1970.isFinite,
                    let resetMinute = normalizedMinute(resetAt),
                    resetAt.timeIntervalSince(snapshot.capturedAt) > -maximumFutureCaptureSkew
                else {
                    continue
                }

                let providerCycleIdentifier = normalizedProviderCycleIdentifier(
                    window.resetCycleIdentifier
                )
                let observedCycleIdentifier = cycleIdentifier(
                    providerCycleIdentifier: providerCycleIdentifier,
                    resetMinute: resetMinute
                )
                let usedPercentage = validUsedPercentage(window.usedPercentage)

                guard let index = state.entries.firstIndex(where: { $0.key == key }) else {
                    state.entries.append(
                        LocalResetDetectionState.Entry(
                            providerID: key.providerID,
                            windowID: key.windowID,
                            cycleIdentifier: observedCycleIdentifier,
                            providerCycleIdentifier: providerCycleIdentifier,
                            resetMinute: resetMinute,
                            capturedAtSecond: capturedAtSecond,
                            usedPercentage: usedPercentage,
                            lastNotifiedCycleIdentifier: nil
                        )
                    )
                    continue
                }

                let previous = state.entries[index]
                guard capturedAtSecond > previous.capturedAtSecond else { continue }

                let observationGap = TimeInterval(capturedAtSecond - previous.capturedAtSecond)
                if observationGap > maximumObservationGap {
                    state.entries[index] = baselineEntry(
                        from: previous,
                        cycleIdentifier: observedCycleIdentifier,
                        providerCycleIdentifier: providerCycleIdentifier,
                        resetMinute: resetMinute,
                        capturedAtSecond: capturedAtSecond,
                        usedPercentage: usedPercentage
                    )
                    continue
                }

                let previousResetAt = Date(
                    timeIntervalSince1970: TimeInterval(previous.resetMinute) * 60
                )
                let resetAdvance = resetAt.timeIntervalSince(previousResetAt)
                let sameProviderCycle = providerCycleIdentifier != nil
                    && providerCycleIdentifier == previous.providerCycleIdentifier
                let providerCycleChanged = providerCycleIdentifier != nil
                    && previous.providerCycleIdentifier != nil
                    && providerCycleIdentifier != previous.providerCycleIdentifier
                let isSmallTimestampAdjustment = abs(resetAdvance) <= resetTimestampTolerance

                if sameProviderCycle || isSmallTimestampAdjustment {
                    var updated = previous
                    updated.providerCycleIdentifier = providerCycleIdentifier
                        ?? previous.providerCycleIdentifier
                    updated.resetMinute = resetMinute
                    updated.capturedAtSecond = capturedAtSecond
                    updated.usedPercentage = usedPercentage
                    state.entries[index] = updated
                    continue
                }

                let previousBoundaryReached = previousResetAt.timeIntervalSince(snapshot.capturedAt)
                    <= maximumFutureCaptureSkew
                let usageDroppedSubstantially = substantialDrop(
                    from: previous.usedPercentage,
                    to: usedPercentage
                )
                let resetAdvancedByNewWindow = resetAdvance >= minimumResetAdvance(
                    for: window.duration
                )
                let isGenuineReset = providerCycleChanged
                    || (resetAdvance > resetTimestampTolerance
                        && (previousBoundaryReached
                            || (usageDroppedSubstantially && resetAdvancedByNewWindow)))

                var updated = baselineEntry(
                    from: previous,
                    cycleIdentifier: observedCycleIdentifier,
                    providerCycleIdentifier: providerCycleIdentifier,
                    resetMinute: resetMinute,
                    capturedAtSecond: capturedAtSecond,
                    usedPercentage: usedPercentage
                )

                if isGenuineReset,
                   previous.lastNotifiedCycleIdentifier != observedCycleIdentifier {
                    updated.lastNotifiedCycleIdentifier = observedCycleIdentifier
                    resets.append(
                        DetectedQuotaReset(
                            identity: QuotaResetWindowIdentity(
                                providerID: key.providerID,
                                windowID: key.windowID,
                                cycleIdentifier: observedCycleIdentifier
                            ),
                            windowLabel: window.label,
                            windowDuration: window.duration,
                            detectedAt: snapshot.capturedAt,
                            resetAt: resetAt
                        )
                    )
                }
                state.entries[index] = updated
            }
        }

        state.entries = Array(
            state.entries
                .sorted { lhs, rhs in
                    if lhs.capturedAtSecond != rhs.capturedAtSecond {
                        return lhs.capturedAtSecond > rhs.capturedAtSecond
                    }
                    if lhs.providerID.rawValue != rhs.providerID.rawValue {
                        return lhs.providerID.rawValue < rhs.providerID.rawValue
                    }
                    return lhs.windowID < rhs.windowID
                }
                .prefix(max(maximumPersistedEntries, 0))
        )
        resets.removeAll { reset in
            !state.entries.contains { entry in
                entry.key == LocalResetDetectionState.Key(
                    providerID: reset.identity.providerID,
                    windowID: reset.identity.windowID
                ) && entry.cycleIdentifier == reset.identity.cycleIdentifier
            }
        }

        return LocalResetDetectionEvaluation(state: state, resets: resets)
    }

    func isFreshForDelivery(_ reset: DetectedQuotaReset, now: Date) -> Bool {
        let age = now.timeIntervalSince(reset.detectedAt)
        return age >= -maximumFutureCaptureSkew && age <= maximumSnapshotAge
    }

    private func validState(from state: LocalResetDetectionState) -> LocalResetDetectionState {
        guard state.schemaVersion == LocalResetDetectionState.currentSchemaVersion else {
            return LocalResetDetectionState()
        }
        return state
    }

    private func isFresh(_ snapshot: ProviderUsageSnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        return age >= -maximumFutureCaptureSkew && age <= maximumSnapshotAge
    }

    private func baselineEntry(
        from previous: LocalResetDetectionState.Entry,
        cycleIdentifier: String,
        providerCycleIdentifier: String?,
        resetMinute: Int64,
        capturedAtSecond: Int64,
        usedPercentage: Double?
    ) -> LocalResetDetectionState.Entry {
        LocalResetDetectionState.Entry(
            providerID: previous.providerID,
            windowID: previous.windowID,
            cycleIdentifier: cycleIdentifier,
            providerCycleIdentifier: providerCycleIdentifier,
            resetMinute: resetMinute,
            capturedAtSecond: capturedAtSecond,
            usedPercentage: usedPercentage,
            lastNotifiedCycleIdentifier: previous.lastNotifiedCycleIdentifier
        )
    }

    private func substantialDrop(from previous: Double?, to current: Double?) -> Bool {
        guard let previous, let current else { return false }
        return previous - current >= substantialUsageDrop
    }

    private func minimumResetAdvance(for duration: Duration?) -> TimeInterval {
        guard let duration, duration > .zero else {
            return minimumResetAdvanceWithoutDuration
        }
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        guard seconds.isFinite, seconds > 0 else {
            return minimumResetAdvanceWithoutDuration
        }
        return max(seconds * minimumResetAdvanceFraction, resetTimestampTolerance)
    }

    private func validUsedPercentage(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private func normalizedProviderCycleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isBoundedIdentifier(trimmed) else { return nil }
        return trimmed
    }

    private func isBoundedIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentifierBytes
    }

    private func cycleIdentifier(
        providerCycleIdentifier: String?,
        resetMinute: Int64
    ) -> String {
        if let providerCycleIdentifier {
            return "provider:\(providerCycleIdentifier)"
        }
        return "reset:\(resetMinute)"
    }

    private func normalizedMinute(_ date: Date) -> Int64? {
        normalizedInteger(date.timeIntervalSince1970 / 60)
    }

    private func normalizedSecond(_ date: Date) -> Int64? {
        normalizedInteger(date.timeIntervalSince1970)
    }

    private func normalizedInteger(_ value: Double) -> Int64? {
        let rounded = value.rounded()
        guard
            rounded.isFinite,
            rounded >= Double(Int64.min),
            rounded <= Double(Int64.max)
        else {
            return nil
        }
        return Int64(rounded)
    }
}
