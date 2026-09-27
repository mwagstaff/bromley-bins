import Foundation

/// An evening-before reminder, independent of UserNotifications so the planning
/// logic can be unit tested.
public struct PlannedReminder: Hashable, Sendable {
    public let id: String
    public let fireDate: Date
    public let collectionDay: CollectionDay
    public let title: String
    public let body: String
}

public enum ReminderPlanner {
    public static let identifierPrefix = "bins.reminder."
    /// iOS keeps at most 64 pending local notifications per app.
    public static let maximumReminders = 30

    /// One reminder per collection day, on the evening before, for the visible
    /// bin types. Reminders whose time has already passed are skipped.
    public static func plan(for state: BinsState, now: Date) -> [PlannedReminder] {
        guard state.reminders.isEnabled, let property = state.property else { return [] }
        let today = CollectionDay(containing: now)

        return state.upcomingGroups(from: today)
            .compactMap { group -> PlannedReminder? in
                let fireDate = group.day.adding(days: -1).date(hour: state.reminders.hour, minute: state.reminders.minute)
                guard fireDate > now else { return nil }
                let types = group.collections.map(\.type).sorted().joined(separator: "+")
                let labels = group.collections.map(\.label)
                return PlannedReminder(
                    id: "\(identifierPrefix)\(property.propertyId).\(group.day.isoString).\(types)",
                    fireDate: fireDate,
                    collectionDay: group.day,
                    title: ReminderMessage.title,
                    body: ReminderMessage.body(labels: labels)
                )
            }
            .prefix(maximumReminders)
            .map { $0 }
    }
}

/// Reminder wording, shared by real reminders and the debug test tools.
public enum ReminderMessage {
    public static let title = "Bins out tonight"

    public static func body(labels: [String]) -> String {
        "\(ScheduleFormatting.list(labels)) \(labels.count == 1 ? "is" : "are") being collected tomorrow."
    }
}
