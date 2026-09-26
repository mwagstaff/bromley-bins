import Foundation

/// Pure schedule queries over persisted state. All "today" logic takes the day
/// as a parameter so it can be tested and so widgets can render future entries.
public extension BinsState {
    /// Collection types present in the schedule, in a stable display order.
    var knownTypes: [BinCollection] {
        var seen = Set<String>()
        return collections
            .sorted { ($0.normalizedType.sortOrder, $0.label) < ($1.normalizedType.sortOrder, $1.label) }
            .filter { seen.insert($0.type).inserted }
    }

    /// Visible collections from `today` onwards, grouped by day.
    func upcomingGroups(from today: CollectionDay) -> [CollectionGroup] {
        let visible = collections.filter { $0.date >= today && !hiddenTypes.contains($0.type) }
        return Dictionary(grouping: visible, by: \.date)
            .map { day, items in
                CollectionGroup(
                    day: day,
                    collections: items.sorted {
                        ($0.normalizedType.sortOrder, $0.label) < ($1.normalizedType.sortOrder, $1.label)
                    }
                )
            }
            .sorted { $0.day < $1.day }
    }

    func nextGroup(from today: CollectionDay) -> CollectionGroup? {
        upcomingGroups(from: today).first
    }

    /// The next date for each visible collection type after `day`, used for the
    /// "later" list so each bin appears once with its next date.
    func nextDateByType(after day: CollectionDay) -> [BinCollection] {
        var nextByType: [String: BinCollection] = [:]
        for collection in collections where collection.date > day && !hiddenTypes.contains(collection.type) {
            if let existing = nextByType[collection.type], existing.date <= collection.date { continue }
            nextByType[collection.type] = collection
        }
        return nextByType.values.sorted {
            ($0.date, $0.normalizedType.sortOrder, $0.label) < ($1.date, $1.normalizedType.sortOrder, $1.label)
        }
    }
}

public extension BinCollectionType {
    var sortOrder: Int {
        switch self {
        case .food: 0
        case .recycling: 1
        case .paper: 2
        case .refuse: 3
        case .garden: 4
        case .other: 5
        }
    }
}

public enum ScheduleFormatting {
    /// "Today", "Tomorrow", or "In 6 days".
    public static func relative(_ day: CollectionDay, from today: CollectionDay) -> String {
        switch today.days(until: day) {
        case 0: "Today"
        case 1: "Tomorrow"
        case let days where days < 0: "Past"
        case let days: "In \(days) days"
        }
    }

    /// "Friday 2 October".
    public static func long(_ day: CollectionDay) -> String {
        day.startDate.formatted(londonStyle.weekday(.wide).day().month(.wide))
    }

    /// "Fri 2 Oct".
    public static func short(_ day: CollectionDay) -> String {
        day.startDate.formatted(londonStyle.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Joins labels as natural English: "Food Waste and Paper & Cardboard".
    public static func list(_ labels: [String]) -> String {
        labels.formatted(.list(type: .and).locale(Locale(identifier: "en_GB")))
    }

    private static var londonStyle: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: Locale(identifier: "en_GB"))
        style.timeZone = CollectionDay.calendar.timeZone
        return style
    }
}
