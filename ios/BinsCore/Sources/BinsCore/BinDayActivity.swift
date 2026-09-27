import Foundation

/// Which part of the reminder window a bin-day Live Activity covers.
///
/// iOS keeps a Live Activity active for at most about eight hours (then up to
/// four more on the Lock Screen), so one activity can't last from the evening
/// before until bin day ends. The window is covered by two in relay: one from
/// the reminder time, and a fresh one on the morning of collection.
public enum BinDayPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case eveningBefore
    case collectionDay

    public var headline: String {
        switch self {
        case .eveningBefore: "Bins out tonight"
        case .collectionDay: "Bin day today"
        }
    }
}

public struct BinDayItem: Codable, Hashable, Sendable {
    public let label: String
    public let type: BinCollectionType

    public init(label: String, type: BinCollectionType) {
        self.label = label
        self.type = type
    }
}

/// A Live Activity the app wants to exist, independent of ActivityKit so the
/// timing rules can be unit tested.
public struct PlannedBinDayActivity: Hashable, Sendable {
    /// Identifies the activity across launches: property, day and phase.
    public let key: String
    public let day: CollectionDay
    public let phase: BinDayPhase
    public let items: [BinDayItem]
    /// When it should appear, or nil to start straight away.
    public let start: Date?
    /// End of bin day: after this the activity is out of date.
    public let staleDate: Date
}

public enum BinDayActivityPlanner {
    /// Wall-clock time the collection-day activity takes over.
    public static let morningHour = 7

    /// The activities for the next visible collection day whose window has not
    /// yet finished. Only the next day is planned: iOS limits pending
    /// activities, and the app re-plans every time it runs.
    public static func plan(for state: BinsState, now: Date) -> [PlannedBinDayActivity] {
        guard state.reminders.isEnabled, state.reminders.showsLiveActivity,
              let property = state.property
        else { return [] }

        let today = CollectionDay(containing: now)
        guard let group = state.upcomingGroups(from: today).first else { return [] }

        let eveningStart = group.day.adding(days: -1).date(hour: state.reminders.hour, minute: state.reminders.minute)
        let morningStart = group.day.date(hour: morningHour, minute: 0)
        let dayEnd = group.day.adding(days: 1).startDate
        guard now < dayEnd else { return [] }

        let items = group.collections.map { BinDayItem(label: $0.label, type: $0.normalizedType) }
        func activity(_ phase: BinDayPhase, start: Date) -> PlannedBinDayActivity {
            PlannedBinDayActivity(
                key: key(propertyId: property.propertyId, day: group.day, phase: phase),
                day: group.day,
                phase: phase,
                items: items,
                start: start > now ? start : nil,
                staleDate: dayEnd
            )
        }

        if now < morningStart {
            return [activity(.eveningBefore, start: eveningStart), activity(.collectionDay, start: morningStart)]
        }
        return [activity(.collectionDay, start: morningStart)]
    }

    public static func key(propertyId: String, day: CollectionDay, phase: BinDayPhase) -> String {
        "\(propertyId).\(day.isoString).\(phase.rawValue)"
    }
}

#if os(iOS)
import ActivityKit

public struct BinDayActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var items: [BinDayItem]

        public init(items: [BinDayItem]) {
            self.items = items
        }
    }

    public let key: String
    public let day: CollectionDay
    public let phase: BinDayPhase
    /// Started from the debug tools; ignored by reconciliation.
    public let isTest: Bool

    public init(key: String, day: CollectionDay, phase: BinDayPhase, isTest: Bool = false) {
        self.key = key
        self.day = day
        self.phase = phase
        self.isTest = isTest
    }
}
#endif
