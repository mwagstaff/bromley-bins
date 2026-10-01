import Foundation

public struct CollectionsResponse: Decodable, Sendable {
    public let propertyId: String
    public let collections: [BinCollection]
    public let lastUpdated: Date
    public let stale: Bool
}

public struct AddressesResponse: Hashable, Sendable {
    public let postcode: String
    public let addresses: [BinAddress]

    public init(postcode: String, addresses: [BinAddress]) {
        self.postcode = postcode
        self.addresses = addresses
    }
}

/// What the server needs to send reminders: push tokens, the council property
/// ID and reminder preferences. Never a postcode or address.
public struct DeviceRegistration: Codable, Hashable, Sendable {
    public enum Environment: String, Codable, Sendable {
        case sandbox
        case production
    }

    public struct Reminders: Codable, Hashable, Sendable {
        public let enabled: Bool
        public let hour: Int
        public let minute: Int
        public let showsLiveActivity: Bool
    }

    public let apnsToken: String?
    public let liveActivityToken: String?
    public let environment: Environment
    public let propertyId: String
    public let reminders: Reminders
    public let hiddenTypes: [String]

    public init(
        apnsToken: String?,
        liveActivityToken: String?,
        environment: Environment,
        propertyId: String,
        reminders: ReminderSettings,
        hiddenTypes: Set<String>
    ) {
        self.apnsToken = apnsToken
        self.liveActivityToken = liveActivityToken
        self.environment = environment
        self.propertyId = propertyId
        self.reminders = Reminders(
            enabled: reminders.isEnabled,
            hour: reminders.hour,
            minute: reminders.minute,
            showsLiveActivity: reminders.showsLiveActivity
        )
        self.hiddenTypes = hiddenTypes.sorted()
    }
}

/// A debug-build request for the server to push a test reminder.
public struct TestReminderRequest: Encodable, Sendable {
    public enum Send: String, Encodable, Sendable {
        case both, notification, activity
    }

    public let items: [BinDayItem]
    public let phase: BinDayPhase
    public let delaySeconds: Int
    public let send: Send

    public init(items: [BinDayItem], phase: BinDayPhase, delaySeconds: Int, send: Send) {
        self.items = items
        self.phase = phase
        self.delaySeconds = delaySeconds
        self.send = send
    }
}

public enum BinsAPIError: Error, Equatable, Sendable {
    case invalidPostcode
    case noAddressesFound
    case propertyNotFound
    case rateLimited
    case councilUnavailable
    case offline
    case unexpected(String)

    /// Only failures that say something about the input are worth showing as
    /// such; everything else is "try again later".
    public var userMessage: String {
        switch self {
        case .invalidPostcode: "That doesn't look like a UK postcode."
        case .noAddressesFound: "Bromley Council has no addresses for that postcode."
        case .propertyNotFound: "Bromley Council has no collections for this address."
        case .rateLimited: "Too many requests. Please try again in a minute."
        case .councilUnavailable: "Bromley's bin service isn't responding right now. Please try again later."
        case .offline: "You appear to be offline."
        case .unexpected: "Something went wrong. Please try again."
        }
    }
}

public protocol BinsAPI: Sendable {
    func collections(propertyId: String) async throws(BinsAPIError) -> CollectionsResponse
    func register(_ registration: DeviceRegistration, installationId: UUID) async throws(BinsAPIError)
    func unregister(installationId: UUID) async throws(BinsAPIError)
    func sendTestReminder(_ request: TestReminderRequest, installationId: UUID) async throws(BinsAPIError)
}

public struct BinsAPIClient: BinsAPI {
    public static let productionBaseURL = URL(string: "https://api.skynolimit.dev/bromley-bins")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = BinsAPIClient.productionBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func collections(propertyId: String) async throws(BinsAPIError) -> CollectionsResponse {
        guard propertyId.allSatisfy(\.isASCIIDigit), !propertyId.isEmpty else {
            throw .propertyNotFound
        }
        let data = try await send(URLRequest(url: baseURL.appending(path: "api/bins/\(propertyId)/collections")))
        do {
            return try Self.decoder.decode(CollectionsResponse.self, from: data)
        } catch {
            throw .unexpected("Decoding failed: \(error)")
        }
    }

    public func register(_ registration: DeviceRegistration, installationId: UUID) async throws(BinsAPIError) {
        _ = try await send(jsonRequest("PUT", path: "api/devices/\(installationId.uuidString.lowercased())", body: registration))
    }

    public func unregister(installationId: UUID) async throws(BinsAPIError) {
        var request = URLRequest(url: baseURL.appending(path: "api/devices/\(installationId.uuidString.lowercased())"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    public func sendTestReminder(_ testRequest: TestReminderRequest, installationId: UUID) async throws(BinsAPIError) {
        _ = try await send(jsonRequest("POST", path: "api/devices/\(installationId.uuidString.lowercased())/test", body: testRequest))
    }

    private func jsonRequest(_ method: String, path: String, body: some Encodable) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func send(_ original: URLRequest) async throws(BinsAPIError) -> Data {
        var request = original
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.isConnectivityFailure {
            throw .offline
        } catch {
            throw .unexpected(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.error(status: status, body: data)
        }
        return data
    }

    static func error(status: Int, body: Data) -> BinsAPIError {
        struct Envelope: Decodable {
            struct Body: Decodable { let code: String }
            let error: Body
        }
        let code = (try? JSONDecoder().decode(Envelope.self, from: body))?.error.code
        switch code {
        case "PROPERTY_NOT_FOUND", "INVALID_PROPERTY_ID": return .propertyNotFound
        case "RATE_LIMITED": return .rateLimited
        case "UPSTREAM_ERROR", "UPSTREAM_TIMEOUT": return .councilUnavailable
        default: return status == 429 ? .rateLimited : .unexpected("HTTP \(status)")
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(string, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp \(string)")
        }
        return decoder
    }()
}
