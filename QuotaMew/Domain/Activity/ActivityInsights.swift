import Foundation

enum ActivityInsightPeriod: Int, CaseIterable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
}

enum ActivityInsightValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case noReportedData
    case overflow
}

/// Exact numerator and denominator; missing dates never enter the denominator.
struct ActivityReportedAverage: Equatable, Sendable {
    let reportedTotal: Int64
    let reportedDays: Int

    /// Nearest whole token, with half rounded upward. No floating-point conversion.
    var roundedTokens: Int64 {
        let divisor = Int64(reportedDays)
        let quotient = reportedTotal / divisor
        let remainder = reportedTotal % divisor
        return quotient + (remainder >= divisor - remainder ? 1 : 0)
    }
}

struct ActivityHighestReportedDay: Equatable, Sendable {
    let bucket: ActivityBucket
    let tiedReportedDays: Int
}

struct ActivityInsightWindow: Equatable, Sendable {
    let startSourceDate: ProviderCalendarDate
    let endSourceDate: ProviderCalendarDate
    let coverage: ActivityCoverage
    let reportedTotal: ActivityInsightValue<Int64>
    let dailyReportedAverage: ActivityInsightValue<ActivityReportedAverage>
    let highestReportedDay: ActivityInsightValue<ActivityHighestReportedDay>
}

enum ActivityPercentageChange: Equatable, Sendable {
    case roundedWholePercent(Int64)
    case lessThanOnePercent
    case zeroBaseline
    case overflow
}

struct ActivityPeriodChange: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case increased, decreased, unchanged }
    let currentReportedTotal: Int64
    let previousReportedTotal: Int64
    let delta: Int64
    let percentage: ActivityPercentageChange
    var direction: Direction { delta > 0 ? .increased : delta < 0 ? .decreased : .unchanged }
}

enum ActivityPeriodComparison: Equatable, Sendable {
    case available(ActivityPeriodChange)
    case insufficientCoverage(current: ActivityCoverage, previous: ActivityCoverage)
    case noReportedData
    case overflow
    case sourceDateOutOfRange
}

enum ActivityInsightsQuery: Equatable, Sendable {
    case available(ActivityInsights)
    case noReportedData
    case sourceDateOutOfRange
}

/// Pure, bounded derivation from one normalized in-memory snapshot.
struct ActivityInsights: Equatable, Sendable {
    let period: ActivityInsightPeriod
    let current: ActivityInsightWindow
    let previous: ActivityInsightWindow?
    let comparison: ActivityPeriodComparison

    static func query(_ snapshot: ProviderActivitySnapshot, period: ActivityInsightPeriod) -> ActivityInsightsQuery {
        guard let anchor = snapshot.buckets.last?.sourceDate else { return .noReportedData }
        let days = period.rawValue
        let buckets = Dictionary(uniqueKeysWithValues: snapshot.buckets.map { ($0.sourceDate, $0) })
        guard let current = try? window(ending: anchor, days: days, buckets: buckets) else {
            return .sourceDateOutOfRange
        }
        // A previous range outside the supported civil-date domain does not hide current insights.
        guard let previousEnd = try? current.startSourceDate.addingDays(-1),
              let previous = try? window(ending: previousEnd, days: days, buckets: buckets) else {
            return .available(Self(period: period, current: current, previous: nil,
                                   comparison: .sourceDateOutOfRange))
        }
        return .available(Self(period: period, current: current, previous: previous,
                               comparison: compare(current, previous)))
    }

    private static func window(ending end: ProviderCalendarDate, days: Int,
                               buckets: [ProviderCalendarDate: ActivityBucket]) throws -> ActivityInsightWindow {
        let start = try end.addingDays(1 - days)
        var reported: [ActivityBucket] = []
        var total: Int64 = 0
        var overflow = false
        for offset in 0..<days {
            if let bucket = buckets[try start.addingDays(offset)] {
                reported.append(bucket)
                if !overflow {
                    let result = total.addingReportingOverflow(bucket.reportedTokens)
                    total = result.partialValue
                    overflow = result.overflow
                }
            }
        }
        let coverage = ActivityCoverage(reportedDays: reported.count, expectedDays: days)
        let sum: ActivityInsightValue<Int64>
        let average: ActivityInsightValue<ActivityReportedAverage>
        let highest: ActivityInsightValue<ActivityHighestReportedDay>
        if reported.isEmpty {
            sum = .noReportedData
            average = .noReportedData
            highest = .noReportedData
        } else {
            sum = overflow ? .overflow : .available(total)
            average = overflow ? .overflow : .available(ActivityReportedAverage(
                reportedTotal: total, reportedDays: reported.count))
            let maximum = reported.map(\.reportedTokens).max()!
            let tied = reported.filter { $0.reportedTokens == maximum }
            // Latest source date wins ties; explicit zeros participate.
            highest = .available(ActivityHighestReportedDay(bucket: tied.last!, tiedReportedDays: tied.count))
        }
        return ActivityInsightWindow(startSourceDate: start, endSourceDate: end, coverage: coverage,
                                     reportedTotal: sum, dailyReportedAverage: average, highestReportedDay: highest)
    }

    private static func compare(_ current: ActivityInsightWindow,
                                _ previous: ActivityInsightWindow) -> ActivityPeriodComparison {
        guard current.coverage.reportedDays > 0 else { return .noReportedData }
        guard current.coverage.isComplete, previous.coverage.isComplete else {
            return .insufficientCoverage(current: current.coverage, previous: previous.coverage)
        }
        guard case .available(let currentTotal) = current.reportedTotal,
              case .available(let previousTotal) = previous.reportedTotal else { return .overflow }
        let (delta, overflow) = currentTotal.subtractingReportingOverflow(previousTotal)
        guard !overflow else { return .overflow }
        return .available(ActivityPeriodChange(currentReportedTotal: currentTotal,
            previousReportedTotal: previousTotal, delta: delta,
            percentage: percentage(delta: delta, baseline: previousTotal)))
    }

    private static func percentage(delta: Int64, baseline: Int64) -> ActivityPercentageChange {
        guard delta != 0 else { return .roundedWholePercent(0) }
        guard baseline > 0 else { return .zeroBaseline }
        let divisor = UInt64(baseline)
        // Nonnegative Int64 totals imply delta is in -Int64.max...Int64.max.
        let magnitude = UInt64(delta.magnitude)
        let product = magnitude.multipliedFullWidth(by: 100)
        // dividingFullWidth requires the quotient to fit UInt64.
        guard product.high < divisor else { return .overflow }
        let result = divisor.dividingFullWidth(product)
        guard result.quotient > 0 else { return .lessThanOnePercent }
        let (rounded, roundingOverflow) = result.quotient.addingReportingOverflow(
            result.remainder >= divisor - result.remainder ? 1 : 0)
        guard !roundingOverflow, rounded <= UInt64(Int64.max) else { return .overflow }
        return .roundedWholePercent(Int64(rounded))
    }
}
