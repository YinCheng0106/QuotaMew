import Foundation

enum ResetNotificationKind: Equatable, Sendable {
    case resetApproaching
    case significantRemaining
}

struct ResetNotificationDecision: Equatable, Sendable {
    let identifier: String
    let providerID: ProviderID
    let windowID: String
    let resetWindowIdentityMinute: Int64
    let thresholdMinutes: Int
    let thresholdsToMark: [Int]
    let kind: ResetNotificationKind
    let title: String
    let body: String
}

struct ResetNotificationEvaluation: Equatable, Sendable {
    let state: NotificationDeduplicationState
    let decisions: [ResetNotificationDecision]
}

struct NotificationDeduplicationState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var entries: [Entry] = []

    struct Entry: Codable, Equatable, Sendable {
        let providerID: ProviderID
        let windowID: String
        let resetWindowIdentityMinute: Int64
        var currentResetMinute: Int64
        var emittedThresholdMinutes: [Int]
        var lastObservedMinute: Int64

        private enum CodingKeys: String, CodingKey {
            case providerID
            case windowID
            case resetWindowIdentityMinute
            case currentResetMinute
            case emittedThresholdMinutes
            case emittedThresholdHours
            case lastObservedMinute
        }

        init(
            providerID: ProviderID,
            windowID: String,
            resetWindowIdentityMinute: Int64,
            currentResetMinute: Int64,
            emittedThresholdMinutes: [Int],
            lastObservedMinute: Int64
        ) {
            self.providerID = providerID
            self.windowID = windowID
            self.resetWindowIdentityMinute = resetWindowIdentityMinute
            self.currentResetMinute = currentResetMinute
            self.emittedThresholdMinutes = emittedThresholdMinutes
            self.lastObservedMinute = lastObservedMinute
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerID = try container.decode(ProviderID.self, forKey: .providerID)
            windowID = try container.decode(String.self, forKey: .windowID)
            resetWindowIdentityMinute = try container.decode(
                Int64.self,
                forKey: .resetWindowIdentityMinute
            )
            currentResetMinute = try container.decode(Int64.self, forKey: .currentResetMinute)
            lastObservedMinute = try container.decode(Int64.self, forKey: .lastObservedMinute)

            if let minutes = try container.decodeIfPresent(
                [Int].self,
                forKey: .emittedThresholdMinutes
            ) {
                emittedThresholdMinutes = minutes
            } else {
                let legacyHours = try container.decodeIfPresent(
                    [Int].self,
                    forKey: .emittedThresholdHours
                ) ?? []
                emittedThresholdMinutes = legacyHours.compactMap { hours in
                    guard hours > 0, hours <= Int.max / 60 else { return nil }
                    return hours * 60
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(providerID, forKey: .providerID)
            try container.encode(windowID, forKey: .windowID)
            try container.encode(resetWindowIdentityMinute, forKey: .resetWindowIdentityMinute)
            try container.encode(currentResetMinute, forKey: .currentResetMinute)
            try container.encode(emittedThresholdMinutes, forKey: .emittedThresholdMinutes)
            try container.encode(lastObservedMinute, forKey: .lastObservedMinute)
        }

        var key: Key {
            Key(providerID: providerID, windowID: windowID)
        }
    }

    struct Key: Hashable, Sendable {
        let providerID: ProviderID
        let windowID: String
    }

    mutating func markEmitted(_ decision: ResetNotificationDecision) {
        let key = Key(providerID: decision.providerID, windowID: decision.windowID)
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        guard entries[index].resetWindowIdentityMinute == decision.resetWindowIdentityMinute else {
            return
        }

        let marked = Set(entries[index].emittedThresholdMinutes)
            .union(decision.thresholdsToMark)
        entries[index].emittedThresholdMinutes = marked.sorted(by: >)
    }
}

enum NotificationWindowClass: String, CaseIterable, Sendable {
    case short
    case long
}

struct ResetNotificationPolicy: Equatable, Sendable {
    static let v01 = ResetNotificationPolicy(
        shortWindowThresholdMinutes: [60, 30],
        longWindowThresholdMinutes: [24 * 60, 6 * 60, 60],
        shortWindowMaximumDuration: .seconds(6 * 60 * 60),
        significantRemainingPercentage: 20,
        maximumSnapshotAge: 15 * 60,
        maximumFutureCaptureSkew: 5 * 60,
        resetTimestampTolerance: 2 * 60,
        maximumPersistedEntries: 32
    )

    let shortWindowThresholdMinutes: [Int]
    let longWindowThresholdMinutes: [Int]
    let shortWindowMaximumDuration: Duration
    let significantRemainingPercentage: Double
    let maximumSnapshotAge: TimeInterval
    let maximumFutureCaptureSkew: TimeInterval
    let resetTimestampTolerance: TimeInterval
    let maximumPersistedEntries: Int

    func evaluate(
        _ providerStates: [ProviderState],
        state originalState: NotificationDeduplicationState,
        now: Date,
        enabledThresholdMinutes: [NotificationWindowClass: Set<Int>]? = nil,
        locale: Locale = .autoupdatingCurrent
    ) -> ResetNotificationEvaluation {
        var state = validState(from: originalState)
        var decisions: [ResetNotificationDecision] = []
        var evaluatedKeys: Set<NotificationDeduplicationState.Key> = []
        for providerState in providerStates {
            guard providerState.status == .available else { continue }
            guard
                let snapshot = providerState.snapshot,
                snapshot.providerID == providerState.providerID,
                snapshot.source.kind != .mock,
                isFresh(snapshot, now: now)
            else {
                continue
            }

            for window in snapshot.windows {
                let presentation = UsageWindowPresentation(
                    providerID: providerState.providerID,
                    window: window
                )
                // Reserve is informational in v0.2; no new fallback-quota reminders.
                guard !presentation.isReserve else { continue }
                guard
                    let resetAt = window.resetAt,
                    resetAt.timeIntervalSince1970.isFinite,
                    normalizedMinute(resetAt) != nil
                else {
                    continue
                }

                let key = NotificationDeduplicationState.Key(
                    providerID: providerState.providerID,
                    windowID: window.id
                )
                guard evaluatedKeys.insert(key).inserted else { continue }

                guard let entry = reconciledEntry(
                    for: key,
                    resetAt: resetAt,
                    in: state,
                    now: now
                ) else { continue }
                replace(entry, in: &state)

                let timeUntilReset = resetAt.timeIntervalSince(now)
                guard timeUntilReset > 0 else { continue }

                guard let windowClass = windowClass(for: window) else { continue }
                let configuredThresholds = Set(thresholdMinutes(for: windowClass))
                let enabledThresholds = enabledThresholdMinutes?[windowClass]
                    .map { configuredThresholds.intersection($0) }
                    ?? configuredThresholds
                let windowDurationMinutes = durationMinutes(window.duration)
                let orderedThresholds = enabledThresholds.filter { thresholdMinutes in
                    guard let windowDurationMinutes else { return false }
                    return thresholdMinutes > 0 && thresholdMinutes <= windowDurationMinutes
                }.sorted(by: >)

                let emitted = Set(entry.emittedThresholdMinutes)
                let crossedThresholds = orderedThresholds.filter { thresholdMinutes in
                    timeUntilReset <= TimeInterval(thresholdMinutes) * 60
                        && !emitted.contains(thresholdMinutes)
                }
                guard let selectedThreshold = crossedThresholds.last else { continue }

                let remainingPercentage = validRemainingPercentage(for: window)
                let kind: ResetNotificationKind
                let body: String
                if let remainingPercentage,
                   remainingPercentage >= significantRemainingPercentage {
                    kind = .significantRemaining
                    body = AppLocalization.notificationRemainingBody(
                        Int(remainingPercentage.rounded()),
                        locale: locale
                    )
                } else {
                    kind = .resetApproaching
                    body = AppLocalization.string(
                        "Your quota window is approaching its scheduled reset.",
                        locale: locale
                    )
                }

                decisions.append(
                    ResetNotificationDecision(
                        identifier: notificationIdentifier(
                            entry: entry,
                            windowClass: windowClass,
                            thresholdMinutes: selectedThreshold
                        ),
                        providerID: providerState.providerID,
                        windowID: window.id,
                        resetWindowIdentityMinute: entry.resetWindowIdentityMinute,
                        thresholdMinutes: selectedThreshold,
                        thresholdsToMark: crossedThresholds,
                        kind: kind,
                        title: AppLocalization.notificationTitle(
                            providerName: providerState.providerID.displayName,
                            windowName: presentation.displayName(locale: locale),
                            thresholdMinutes: selectedThreshold,
                            locale: locale
                        ),
                        body: body
                    )
                )
            }
        }

        state.entries = Array(
            state.entries
                .sorted { lhs, rhs in
                    if lhs.lastObservedMinute != rhs.lastObservedMinute {
                        return lhs.lastObservedMinute > rhs.lastObservedMinute
                    }
                    if lhs.providerID.rawValue != rhs.providerID.rawValue {
                        return lhs.providerID.rawValue < rhs.providerID.rawValue
                    }
                    return lhs.windowID < rhs.windowID
                }
                .prefix(max(maximumPersistedEntries, 0))
        )
        decisions.removeAll { decision in
            !state.entries.contains { entry in
                entry.providerID == decision.providerID
                    && entry.windowID == decision.windowID
                    && entry.resetWindowIdentityMinute == decision.resetWindowIdentityMinute
            }
        }

        return ResetNotificationEvaluation(state: state, decisions: decisions)
    }

    private func validState(
        from state: NotificationDeduplicationState
    ) -> NotificationDeduplicationState {
        guard state.schemaVersion == NotificationDeduplicationState.currentSchemaVersion else {
            return NotificationDeduplicationState()
        }
        return state
    }

    private func isFresh(_ snapshot: ProviderUsageSnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        return age >= -maximumFutureCaptureSkew && age <= maximumSnapshotAge
    }

    private func reconciledEntry(
        for key: NotificationDeduplicationState.Key,
        resetAt: Date,
        in state: NotificationDeduplicationState,
        now: Date
    ) -> NotificationDeduplicationState.Entry? {
        guard
            let resetMinute = normalizedMinute(resetAt),
            let observedMinute = normalizedMinute(now)
        else {
            return nil
        }
        guard let existing = state.entries.first(where: { $0.key == key }) else {
            return NotificationDeduplicationState.Entry(
                providerID: key.providerID,
                windowID: key.windowID,
                resetWindowIdentityMinute: resetMinute,
                currentResetMinute: resetMinute,
                emittedThresholdMinutes: [],
                lastObservedMinute: observedMinute
            )
        }

        let existingReset = Date(
            timeIntervalSince1970: TimeInterval(existing.currentResetMinute) * 60
        )
        let isSmallTimestampAdjustment = abs(resetAt.timeIntervalSince(existingReset))
            <= resetTimestampTolerance
        let existingWindowHasNotPassed = existingReset > now

        if isSmallTimestampAdjustment || existingWindowHasNotPassed {
            var updated = existing
            updated.currentResetMinute = resetMinute
            updated.lastObservedMinute = observedMinute
            return updated
        }

        return NotificationDeduplicationState.Entry(
            providerID: key.providerID,
            windowID: key.windowID,
            resetWindowIdentityMinute: resetMinute,
            currentResetMinute: resetMinute,
            emittedThresholdMinutes: [],
            lastObservedMinute: observedMinute
        )
    }

    private func replace(
        _ entry: NotificationDeduplicationState.Entry,
        in state: inout NotificationDeduplicationState
    ) {
        if let index = state.entries.firstIndex(where: { $0.key == entry.key }) {
            state.entries[index] = entry
        } else {
            state.entries.append(entry)
        }
    }

    private func validRemainingPercentage(for window: UsageWindow) -> Double? {
        guard
            let usedPercentage = window.usedPercentage,
            usedPercentage.isFinite,
            (0...100).contains(usedPercentage)
        else {
            return nil
        }
        return 100 - usedPercentage
    }

    private func normalizedMinute(_ date: Date) -> Int64? {
        let minute = (date.timeIntervalSince1970 / 60).rounded()
        guard
            minute.isFinite,
            minute >= Double(Int64.min),
            minute <= Double(Int64.max)
        else {
            return nil
        }
        return Int64(minute)
    }

    private func notificationIdentifier(
        entry: NotificationDeduplicationState.Entry,
        windowClass: NotificationWindowClass,
        thresholdMinutes: Int
    ) -> String {
        let encodedWindowID = Data(entry.windowID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return [
            "quotapulse.reset",
            entry.providerID.rawValue,
            encodedWindowID,
            String(entry.resetWindowIdentityMinute),
            windowClass.rawValue,
            "\(thresholdMinutes)m",
        ].joined(separator: ".")
    }

    func thresholdMinutes(for windowClass: NotificationWindowClass) -> [Int] {
        switch windowClass {
        case .short: shortWindowThresholdMinutes
        case .long: longWindowThresholdMinutes
        }
    }

    func windowClass(for window: UsageWindow) -> NotificationWindowClass? {
        guard let duration = window.duration, duration > .zero else { return nil }
        return duration <= shortWindowMaximumDuration ? .short : .long
    }

    var allThresholdMinutes: Set<Int> {
        Set(shortWindowThresholdMinutes + longWindowThresholdMinutes)
    }

    private func durationMinutes(_ duration: Duration?) -> Int? {
        guard let duration, duration > .zero else { return nil }
        let components = duration.components
        guard components.seconds <= Int64(Int.max / 60) * 60 else { return nil }
        return Int(components.seconds / 60)
    }

}
