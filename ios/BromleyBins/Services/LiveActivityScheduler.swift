import ActivityKit
import BinsCore
import Foundation
import os

/// Keeps bin-day Live Activities in line with `BinDayActivityPlanner`: starts or
/// schedules what's missing, updates what changed, ends what's no longer wanted.
///
/// Scheduling needs the app to be running, so this runs on every state change,
/// on foregrounding and on background refresh; anything iOS refuses (e.g. from
/// the background) is retried next time. The evening reminder notification is
/// scheduled independently, so it still arrives if an activity couldn't be.
@MainActor
final class LiveActivityScheduler {
    static let shared = LiveActivityScheduler()

    /// A silent sound for the activity's own alert, so the reminder
    /// notification is the only thing that makes a noise.
    static let silentAlertSound = AlertConfiguration.AlertSound.named("silence.caf")

    private let logger = Logger(subsystem: "dev.skynolimit.bromleybins", category: "live-activity")
    /// Keys already requested, so an activity the user dismissed isn't
    /// brought straight back the next time the app runs.
    private let requestedKeysDefaultsKey = "liveActivity.requestedKeys"

    func reconcile(with state: BinsState, now: Date = .now) async {
        let planned = BinDayActivityPlanner.plan(for: state, now: now)
        let plannedByKey = Dictionary(uniqueKeysWithValues: planned.map { ($0.key, $0) })
        var requested = requestedKeys(pruningBefore: CollectionDay(containing: now))

        for activity in Activity<BinDayActivityAttributes>.activities where !activity.attributes.isTest {
            guard let plan = plannedByKey[activity.attributes.key] else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            let content = ActivityContent(state: contentState(for: plan), staleDate: plan.staleDate)
            if activity.content.state != content.state {
                if activity.activityState == .pending {
                    // Re-request a scheduled activity rather than editing it in place.
                    await activity.end(nil, dismissalPolicy: .immediate)
                    requested.remove(plan.key)
                } else {
                    await activity.update(content)
                }
            }
        }

        let existingKeys = Set(Activity<BinDayActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .pending }
            .map(\.attributes.key))

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            saveRequestedKeys(requested)
            return
        }

        for plan in planned where !existingKeys.contains(plan.key) && !requested.contains(plan.key) {
            do {
                try request(plan)
                requested.insert(plan.key)
            } catch {
                logger.notice("Could not request \(plan.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        saveRequestedKeys(requested)
    }

    private func request(_ plan: PlannedBinDayActivity) throws {
        let attributes = BinDayActivityAttributes(key: plan.key, day: plan.day, phase: plan.phase)
        try Self.request(attributes: attributes, items: plan.items, start: plan.start, staleDate: plan.staleDate)
    }

    /// Starts now, or schedules for `start`. Shared with the debug tools.
    static func request(
        attributes: BinDayActivityAttributes,
        items: [BinDayItem],
        start: Date?,
        staleDate: Date
    ) throws {
        let content = ActivityContent(
            state: BinDayActivityAttributes.ContentState(items: items),
            staleDate: staleDate,
            relevanceScore: 100
        )
        if let start {
            let labels = items.map(\.label)
            _ = try Activity.request(
                attributes: attributes,
                content: content,
                style: .standard,
                alertConfiguration: AlertConfiguration(
                    title: LocalizedStringResource(stringLiteral: attributes.phase.headline),
                    body: LocalizedStringResource(stringLiteral: ScheduleFormatting.list(labels)),
                    sound: silentAlertSound
                ),
                start: start
            )
        } else {
            _ = try Activity.request(attributes: attributes, content: content)
        }
    }

    private func contentState(for plan: PlannedBinDayActivity) -> BinDayActivityAttributes.ContentState {
        BinDayActivityAttributes.ContentState(items: plan.items)
    }

    // MARK: - Requested keys

    private func requestedKeys(pruningBefore today: CollectionDay) -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: requestedKeysDefaultsKey) ?? []
        // Keys look like "<propertyId>.<yyyy-mm-dd>.<phase>"; drop past days.
        return Set(stored.filter { key in
            let parts = key.split(separator: ".")
            guard parts.count >= 3, let day = CollectionDay(isoString: String(parts[parts.count - 2])) else { return false }
            return day >= today
        })
    }

    private func saveRequestedKeys(_ keys: Set<String>) {
        UserDefaults.standard.set(keys.sorted(), forKey: requestedKeysDefaultsKey)
    }
}
