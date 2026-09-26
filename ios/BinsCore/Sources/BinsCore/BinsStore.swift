import Foundation
import os

/// Reads and writes `BinsState` as a single JSON file in the App Group
/// container, so the app and the widget extension see the same data.
public struct BinsStore: Sendable {
    public static let appGroupID = "group.dev.skynolimit.bromleybins"

    private static let logger = Logger(subsystem: "dev.skynolimit.bromleybins", category: "store")

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The shared store. Falls back to the process's own Application Support
    /// directory if the App Group is unavailable (e.g. a misconfigured build),
    /// so the app still works — widgets just won't see its data.
    public static func shared() -> BinsStore {
        let directory: URL
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            directory = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        } else {
            logger.error("App Group container unavailable; falling back to app-local storage")
            directory = URL.applicationSupportDirectory
        }
        return BinsStore(fileURL: directory.appending(path: "bins-state.json"))
    }

    public func load() -> BinsState {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder.store.decode(BinsState.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            Self.logger.error("Could not read saved state: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    public func save(_ state: BinsState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.store.encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private extension JSONEncoder {
    static let store: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let store: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public extension BinsState {
    /// Applies a fresh API response. A response with no collections never
    /// replaces a schedule we already have.
    func applying(_ response: CollectionsResponse, receivedAt now: Date) -> BinsState {
        guard response.propertyId == property?.propertyId else { return self }
        var next = self
        if !response.collections.isEmpty || collections.isEmpty {
            next.collections = response.collections
        }
        next.lastSuccessfulRefresh = now
        next.sourceUpdated = response.lastUpdated
        return next
    }

    /// Whether the data on screen should be flagged as possibly out of date.
    func isOutdated(now: Date) -> Bool {
        guard let sourceUpdated else { return true }
        return now.timeIntervalSince(sourceUpdated) > 24 * 60 * 60
    }
}
