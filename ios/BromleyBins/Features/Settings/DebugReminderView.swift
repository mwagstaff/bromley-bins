#if DEBUG
import ActivityKit
import BinsCore
import SwiftUI
import UserNotifications

/// Debug-only tools for firing reminders and Live Activities on demand with a
/// chosen set of bins, instead of waiting for the evening before a collection.
struct DebugReminderView: View {
    @Environment(AppModel.self) private var model

    private enum Delay: Int, CaseIterable, Identifiable {
        case now = 0, fiveSeconds = 5, thirtySeconds = 30, twoMinutes = 120
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .now: "Now"
            case .fiveSeconds: "5 s"
            case .thirtySeconds: "30 s"
            case .twoMinutes: "2 min"
            }
        }
    }

    @State private var selected: Set<BinDayItem> = []
    @State private var phase: BinDayPhase = .eveningBefore
    @State private var delay: Delay = .fiveSeconds
    @State private var status: String?
    @State private var pendingReminders: [UNNotificationRequest] = []
    @State private var activities: [(key: String, state: String, isTest: Bool)] = []

    /// Bins from the saved schedule, plus one of every kind so any combination
    /// (including unknown types) can be tried.
    private var candidates: [BinDayItem] {
        var items = model.state.knownTypes.map { BinDayItem(label: $0.label, type: $0.normalizedType) }
        let samples: [BinDayItem] = [
            BinDayItem(label: "Food Waste", type: .food),
            BinDayItem(label: "Mixed Recycling (Cans, Plastics & Glass)", type: .recycling),
            BinDayItem(label: "Paper & Cardboard", type: .paper),
            BinDayItem(label: "Non-Recyclable Refuse", type: .refuse),
            BinDayItem(label: "Garden Waste", type: .garden),
            BinDayItem(label: "Bulky Items", type: .other),
        ]
        for sample in samples where !items.contains(where: { $0.type == sample.type }) {
            items.append(sample)
        }
        return items
    }

    private var chosenItems: [BinDayItem] {
        candidates.filter(selected.contains)
    }

    var body: some View {
        Form {
            Section("Bins") {
                ForEach(candidates, id: \.self) { item in
                    Toggle(isOn: Binding(
                        get: { selected.contains(item) },
                        set: { if $0 { selected.insert(item) } else { selected.remove(item) } }
                    )) {
                        HStack(spacing: 10) {
                            BinBadge(item.type, size: 26)
                            Text(item.label)
                        }
                    }
                }
            }

            Section {
                Picker("Live Activity", selection: $phase) {
                    Text("Evening before").tag(BinDayPhase.eveningBefore)
                    Text("Collection day").tag(BinDayPhase.collectionDay)
                }
                Picker("Delay", selection: $delay) {
                    ForEach(Delay.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Timing")
            } footer: {
                Text("With a delay, lock the device after tapping to see the reminder arrive on the Lock Screen.")
            }

            Section {
                Button("Send reminder notification") { Task { await sendNotification() } }
                Button("Start Live Activity") { startActivity() }
                Button("Send both") {
                    Task {
                        await sendNotification()
                        startActivity()
                    }
                }
                Button("End test Live Activities", role: .destructive) { Task { await endTestActivities() } }
            } footer: {
                if let status {
                    Text(status)
                }
            }
            .disabled(chosenItems.isEmpty)

            Section {
                Button("Re-sync real reminders now") {
                    Task {
                        await LiveActivityScheduler.shared.reconcile(with: model.state)
                        await reloadScheduled()
                    }
                }
                if pendingReminders.isEmpty {
                    Text("No pending reminder notifications").foregroundStyle(.secondary)
                }
                ForEach(pendingReminders, id: \.identifier) { request in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.content.body).font(.subheadline)
                        if let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                            Text(date, format: .dateTime.weekday().day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(activities, id: \.key) { activity in
                    LabeledContent(activity.key, value: activity.isTest ? "test · \(activity.state)" : activity.state)
                        .font(.caption)
                }
            } header: {
                Text("Scheduled")
            }
        }
        .navigationTitle("Test reminders")
        .task {
            if selected.isEmpty {
                selected = Set(model.state.nextGroup(from: model.today)?.collections
                    .map { BinDayItem(label: $0.label, type: $0.normalizedType) } ?? Array(candidates.prefix(2)))
            }
            await reloadScheduled()
        }
    }

    private func sendNotification() async {
        status = await DebugReminderTester.sendNotification(items: chosenItems, delay: TimeInterval(delay.rawValue))
    }

    private func startActivity() {
        status = DebugReminderTester.startActivity(items: chosenItems, phase: phase, delay: TimeInterval(delay.rawValue))
        Task { await reloadScheduled() }
    }

    private func endTestActivities() async {
        status = await DebugReminderTester.endTestActivities()
        await reloadScheduled()
    }

    private func reloadScheduled() async {
        pendingReminders = await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(ReminderPlanner.identifierPrefix) }
        activities = Activity<BinDayActivityAttributes>.activities.map {
            (key: $0.attributes.key, state: String(describing: $0.activityState), isTest: $0.attributes.isTest)
        }
    }
}

/// The test actions, shared by the debug screen and the debug URL:
///
///     bromleybins://debug/reminder?bins=food,recycling&delay=10&phase=evening
///
/// `bins` takes normalised types (food, recycling, paper, refuse, garden,
/// other); `phase` is `evening` or `day`; `send` is `both` (default),
/// `notification` or `activity`. `bromleybins://debug/end` ends test activities.
@MainActor
enum DebugReminderTester {
    static func handle(_ url: URL) async {
        guard url.scheme == "bromleybins", url.host() == "debug" else { return }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { $1 }
        )
        switch url.path() {
        case "/end":
            _ = await endTestActivities()
        case "/reminder":
            let types = (query["bins"] ?? "food,recycling").split(separator: ",").compactMap { BinCollectionType(rawValue: String($0)) }
            let items = types.map { BinDayItem(label: sampleLabel(for: $0), type: $0) }
            let delay = TimeInterval(query["delay"].flatMap(Int.init) ?? 5)
            let phase: BinDayPhase = query["phase"] == "day" ? .collectionDay : .eveningBefore
            let send = query["send"] ?? "both"
            if send != "activity" { _ = await sendNotification(items: items, delay: delay) }
            if send != "notification" { _ = startActivity(items: items, phase: phase, delay: delay) }
        default:
            break
        }
    }

    static func sendNotification(items: [BinDayItem], delay: TimeInterval) async -> String {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else {
            return "Notifications aren't allowed for this app."
        }
        let content = UNMutableNotificationContent()
        content.title = ReminderMessage.title
        content.body = ReminderMessage.body(labels: items.map(\.label))
        content.sound = .default
        content.threadIdentifier = "bins"
        let seconds = max(delay, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: "bins.debug.\(UUID())", content: content, trigger: trigger))
            return "Notification scheduled in \(Int(seconds)) s."
        } catch {
            return "Notification failed: \(error.localizedDescription)"
        }
    }

    static func startActivity(items: [BinDayItem], phase: BinDayPhase, delay: TimeInterval) -> String {
        let today = CollectionDay(containing: .now)
        let day = phase == .eveningBefore ? today.adding(days: 1) : today
        let attributes = BinDayActivityAttributes(key: "debug.\(UUID().uuidString.prefix(8))", day: day, phase: phase, isTest: true)
        do {
            try LiveActivityScheduler.request(
                attributes: attributes,
                items: items,
                start: delay > 0 ? Date.now.addingTimeInterval(delay) : nil,
                staleDate: day.adding(days: 1).startDate
            )
            return delay > 0 ? "Live Activity scheduled in \(Int(delay)) s." : "Live Activity started."
        } catch {
            return "Live Activity failed: \(error.localizedDescription)"
        }
    }

    static func endTestActivities() async -> String {
        for activity in Activity<BinDayActivityAttributes>.activities where activity.attributes.isTest {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return "Ended test Live Activities."
    }

    private static func sampleLabel(for type: BinCollectionType) -> String {
        switch type {
        case .food: "Food Waste"
        case .recycling: "Mixed Recycling (Cans, Plastics & Glass)"
        case .paper: "Paper & Cardboard"
        case .refuse: "Non-Recyclable Refuse"
        case .garden: "Garden Waste"
        case .other: "Bulky Items"
        }
    }
}
#endif
