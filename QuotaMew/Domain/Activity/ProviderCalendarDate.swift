/// A provider-reported Gregorian calendar date, never an absolute instant.
struct ProviderCalendarDate: Equatable, Hashable, Comparable, Sendable {
    let rawValue: String

    init(_ source: String) throws {
        // Bound before allocating a byte array; reject non-ASCII and normalization.
        guard source.utf8.count == 10 else { throw ActivityFetchError.invalidData }
        let bytes = Array(source.utf8)
        guard bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }) else { throw ActivityFetchError.invalidData }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        guard year > 0, (1...12).contains(month) else { throw ActivityFetchError.invalidData }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { throw ActivityFetchError.invalidData }
        rawValue = source
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Zero-based proleptic Gregorian day number (0001-01-01 = 0).
    var ordinal: Int {
        let parts = rawValue.split(separator: "-").map { Int($0)! }
        let year = parts[0], month = parts[1], day = parts[2]
        return Self.daysBeforeYear(year)
            + Self.monthLengths(year).prefix(month - 1).reduce(0, +) + day - 1
    }

    func distance(to other: Self) -> Int { other.ordinal - ordinal }

    /// Out-of-domain dates and integer overflow fail rather than truncate a range.
    func addingDays(_ offset: Int) throws -> Self {
        let (target, overflow) = ordinal.addingReportingOverflow(offset)
        guard !overflow, (0..<Self.daysBeforeYear(10000)).contains(target) else {
            throw ActivityFetchError.invalidData
        }
        var lower = 1, upper = 10000
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if Self.daysBeforeYear(middle) <= target { lower = middle } else { upper = middle }
        }
        var remainder = target - Self.daysBeforeYear(lower)
        let months = Self.monthLengths(lower)
        var month = 1
        while remainder >= months[month - 1] {
            remainder -= months[month - 1]
            month += 1
        }
        func padded(_ value: Int, width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: width - text.count) + text
        }
        return try Self("\(padded(lower, width: 4))-\(padded(month, width: 2))-\(padded(remainder + 1, width: 2))")
    }

    private static func daysBeforeYear(_ year: Int) -> Int {
        let previous = year - 1
        return 365 * previous + previous / 4 - previous / 100 + previous / 400
    }

    private static func monthLengths(_ year: Int) -> [Int] {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    }
}
