import BinsCore
import Foundation
import UserNotifications

/// Fallback for when the server isn't sending reminders (e.g. not yet
/// registered): turns `ReminderPlanner`'s plan into local notifications. Every
/// reschedule removes all of our pending reminders and adds the fresh plan, so
/// a changed schedule can never leave a reminder for a cancelled collection.
struct ReminderScheduler: Sendable {
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// `serverSends`: the server has confirmed it will push these reminders,
    /// so local ones are cleared to avoid duplicates.
    func reschedule(for state: BinsState, serverSends: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(ReminderPlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard !serverSends else { return }

        for reminder in ReminderPlanner.plan(for: state, now: .now) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = "bins"

            let components = CollectionDay.calendar.dateComponents(
                in: CollectionDay.calendar.timeZone,
                from: reminder.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(
                    calendar: CollectionDay.calendar,
                    timeZone: CollectionDay.calendar.timeZone,
                    year: components.year,
                    month: components.month,
                    day: components.day,
                    hour: components.hour,
                    minute: components.minute
                ),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }
}
