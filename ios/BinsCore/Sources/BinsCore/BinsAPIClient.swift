import Foundation

public struct CollectionsResponse: Decodable, Sendable {
    public let propertyId: String
    public let collections: [BinCollection]
    public let lastUpdated: Date
    public let stale: Bool
}

public struct AddressesResponse: Decodable, Sendable {
    public let postcode: String
    public let addresses: [BinAddress]
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
    func addresses(postcode: String) async throws(BinsAPIError) -> AddressesResponse
    func collections(propertyId: String) async throws(BinsAPIError) -> CollectionsResponse
}

public struct BinsAPIClient: BinsAPI {
    public static let productionBaseURL = URL(string: "https://api.skynolimit.dev/bin-collections")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = BinsAPIClient.productionBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func addresses(postcode: String) async throws(BinsAPIError) -> AddressesResponse {
        var components = URLComponents(
            url: baseURL.appending(path: "api/bins/addresses"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "postcode", value: postcode)]
        return try await get(components.url!)
    }

    public func collections(propertyId: String) async throws(BinsAPIError) -> CollectionsResponse {
        guard propertyId.allSatisfy(\.isASCIIDigit), !propertyId.isEmpty else {
            throw .propertyNotFound
        }
        return try await get(baseURL.appending(path: "api/bins/\(propertyId)/collections"))
    }

    private func get<T: Decodable>(_ url: URL) async throws(BinsAPIError) -> T {
        var request = URLRequest(url: url, timeoutInterval: 20)
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
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw .unexpected("Decoding failed: \(error)")
        }
    }

    static func error(status: Int, body: Data) -> BinsAPIError {
        struct Envelope: Decodable {
            struct Body: Decodable { let code: String }
            let error: Body
        }
        let code = (try? JSONDecoder().decode(Envelope.self, from: body))?.error.code
        switch code {
        case "INVALID_POSTCODE": return .invalidPostcode
        case "NO_ADDRESSES_FOUND": return .noAddressesFound
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

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private extension URLError {
    var isConnectivityFailure: Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
         .timedOut, .dataNotAllowed, .internationalRoamingOff].contains(code)
    }
}
