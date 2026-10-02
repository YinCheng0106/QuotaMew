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
}
