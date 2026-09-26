import Foundation

/// A calendar day with no time or time zone attached. Bin collections happen on
/// a day, not at an instant, so they are never stored as `Date` — that is what
/// stops a collection sliding onto the wrong day across time zones or DST.
public struct CollectionDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Collections are scheduled by a London council, so "today" is London's today.
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    public init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: Self.calendar) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`.
    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The London calendar day containing `date`.
    public init(containing date: Date) {
        let components = Self.calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year!
        month = components.month!
        day = components.day!
    }

    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { isoString }

    /// Midnight at the start of this day in London.
    public var startDate: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A moment on this day at the given London wall-clock time.
    public func date(hour: Int, minute: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    public func adding(days: Int) -> CollectionDay {
        CollectionDay(containing: Self.calendar.date(byAdding: .day, value: days, to: date(hour: 12, minute: 0))!)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: CollectionDay) -> Int {
        Self.calendar.dateComponents([.day], from: startDate, to: other.startDate).day!
    }

    public static func < (lhs: CollectionDay, rhs: CollectionDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = CollectionDay(isoString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}
