import Foundation

public struct BinAddress: Codable, Hashable, Identifiable, Sendable {
    public let propertyId: String
    public let address: String

    public var id: String { propertyId }

    public init(propertyId: String, address: String) {
        self.propertyId = propertyId
        self.address = address
    }
}

/// Broad kinds of collection, used only to pick an icon and colour. Anything
/// the API does not recognise decodes as `.other` and is still shown.
public enum BinCollectionType: String, Codable, CaseIterable, Sendable {
    case food
    case recycling
    case paper
    case refuse
    case garden
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BinCollectionType(rawValue: raw) ?? .other
    }
}

public struct BinCollection: Codable, Hashable, Identifiable, Sendable {
    public let date: CollectionDay
    /// Raw upstream name, e.g. "Food Waste collection". Stable identity for the
    /// collection stream and what the user's bin filter is keyed on.
    public let type: String
    /// Display name, e.g. "Food Waste".
    public let label: String
    public let normalizedType: BinCollectionType

    public var id: String { "\(date.isoString)-\(type)" }

    public init(date: CollectionDay, type: String, label: String? = nil, normalizedType: BinCollectionType = .other) {
        self.date = date
        self.type = type
        self.label = label ?? type
        self.normalizedType = normalizedType
    }

    private enum CodingKeys: String, CodingKey {
        case date, type, label, normalizedType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(CollectionDay.self, forKey: .date)
        type = try container.decode(String.self, forKey: .type)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? type
        normalizedType = try container.decodeIfPresent(BinCollectionType.self, forKey: .normalizedType) ?? .other
    }
}

/// The address the user picked. The WasteWorks property ID is an external
/// reference we look collections up by, not an identity we own.
public struct SavedProperty: Codable, Hashable, Sendable {
    public let propertyId: String
    public let displayAddress: String
    public let postcode: String

    public init(propertyId: String, displayAddress: String, postcode: String) {
        self.propertyId = propertyId
        self.displayAddress = displayAddress
        self.postcode = postcode
    }
}

/// One day's collections, in display order.
public struct CollectionGroup: Hashable, Identifiable, Sendable {
    public let day: CollectionDay
    public let collections: [BinCollection]

    public var id: CollectionDay { day }

    public init(day: CollectionDay, collections: [BinCollection]) {
        self.day = day
        self.collections = collections
    }
}

public struct ReminderSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// London wall-clock time on the evening before a collection.
    public var hour: Int
    public var minute: Int

    public init(isEnabled: Bool = false, hour: Int = 19, minute: Int = 0) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
    }
}

/// Everything the app and widgets persist, stored as one JSON document in the
/// App Group container.
public struct BinsState: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var property: SavedProperty?
    public var collections: [BinCollection]
    /// When the app last received a schedule from the API.
    public var lastSuccessfulRefresh: Date?
    /// When the API last got this schedule from the council.
    public var sourceUpdated: Date?
    /// Raw collection types the user has switched off.
    public var hiddenTypes: Set<String>
    public var reminders: ReminderSettings

    public init(
        property: SavedProperty? = nil,
        collections: [BinCollection] = [],
        lastSuccessfulRefresh: Date? = nil,
        sourceUpdated: Date? = nil,
        hiddenTypes: Set<String> = [],
        reminders: ReminderSettings = ReminderSettings()
    ) {
        version = Self.currentVersion
        self.property = property
        self.collections = collections
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.sourceUpdated = sourceUpdated
        self.hiddenTypes = hiddenTypes
        self.reminders = reminders
    }

    public static let empty = BinsState()
}
