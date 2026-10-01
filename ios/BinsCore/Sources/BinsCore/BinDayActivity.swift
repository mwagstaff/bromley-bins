import Foundation

/// Which part of the reminder window a bin-day Live Activity covers.
///
/// iOS keeps a Live Activity active for at most about eight hours (then up to
/// four more on the Lock Screen), so one activity can't last from the evening
/// before until bin day ends. The window is covered by two in relay: one from
/// the reminder time, and a fresh one once the first has been removed.
///
/// The evening card goes stale at midnight, and its view then reads as a
/// bin-day card, so it's right overnight without needing an update.
public enum BinDayPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case eveningBefore
    case collectionDay

    public var headline: String {
        headline(isStale: false)
    }

    /// What the card says, given whether its stale date has passed.
    public func headline(isStale: Bool) -> String {
        switch (self, isStale) {
        case (.eveningBefore, false): "Bins out tonight"
        case (.eveningBefore, true), (.collectionDay, false): "Bin day today"
        case (.collectionDay, true): "Collection day has passed"
        }
    }

    /// Whether the bins are still worth listing once stale.
    public func showsItems(isStale: Bool) -> Bool {
        self == .eveningBefore || !isStale
    }

    /// When a card for a collection on `day` becomes stale: the evening card
    /// at the start of collection day, the bin-day card when it ends.
    public func staleDate(for day: CollectionDay) -> Date {
        switch self {
        case .eveningBefore: day.startDate
        case .collectionDay: day.adding(days: 1).startDate
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
    /// iOS removes a Live Activity at most this long after it starts (eight
    /// hours active plus four on the Lock Screen). The bin-day card starts then,
    /// so the two never show at once: 07:00 for the default 19:00 reminder.
    public static let maximumLifetime: TimeInterval = 12 * 60 * 60

    /// When the bin-day card takes over from the evening card started at
    /// `eveningStart`: twelve hours later, but never before collection day.
    public static func collectionDayStart(eveningStart: Date, day: CollectionDay) -> Date {
        max(eveningStart.addingTimeInterval(maximumLifetime), day.startDate)
    }

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
        let morningStart = collectionDayStart(eveningStart: eveningStart, day: group.day)
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
                staleDate: phase.staleDate(for: group.day)
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
