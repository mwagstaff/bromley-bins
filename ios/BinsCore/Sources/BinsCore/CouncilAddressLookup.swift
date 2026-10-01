import Foundation

/// Looks up addresses for a postcode directly with Bromley's WasteWorks site,
/// so postcodes and addresses never pass through our server. Only the chosen
/// address's council property ID is shared with it, for reminders.
public protocol AddressLookup: Sendable {
    func addresses(postcode: String) async throws(BinsAPIError) -> AddressesResponse
}

public struct CouncilAddressLookup: AddressLookup {
    public static let bromleyBaseURL = URL(string: "https://recyclingservices.bromley.gov.uk/")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = CouncilAddressLookup.bromleyBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func addresses(postcode rawPostcode: String) async throws(BinsAPIError) -> AddressesResponse {
        guard let postcode = Postcode.normalize(rawPostcode) else { throw .invalidPostcode }

        var request = URLRequest(url: baseURL.appending(path: "waste"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "postcode", value: postcode)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.isConnectivityFailure {
            throw .offline
        } catch {
            throw .unexpected(error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw .councilUnavailable
        }

        let addresses: [BinAddress]
        do {
            addresses = try WasteWorksAddressParser.parse(String(decoding: data, as: UTF8.self))
        } catch {
            throw .councilUnavailable
        }
        guard !addresses.isEmpty else { throw .noAddressesFound }
        return AddressesResponse(postcode: postcode, addresses: addresses)
    }
}

public enum Postcode {
    /// Canonicalises a UK postcode ("br31aa", "BR3  1AA" → "BR3 1AA"), or nil
    /// for anything that can't be one, so junk is never sent to the council.
    public static func normalize(_ input: String) -> String? {
        let compact = input.uppercased().filter { !$0.isWhitespace }
        guard compact.wholeMatch(of: /[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}/) != nil else { return nil }
        return "\(compact.dropLast(3)) \(compact.suffix(3))"
    }
}

/// Reads the address picker from WasteWorks' postcode results page.
public enum WasteWorksAddressParser {
    public enum ParseError: Error, Equatable {
        /// Neither a results page nor a "no results" page: the markup changed.
        case addressSelectMissing
        case noNumericOptions
    }

    /// The addresses on the page, or an empty list when WasteWorks says it
    /// found nothing for the postcode. Throws when the page is unrecognisable,
    /// so a markup change shows up as a problem rather than "no addresses".
    public static func parse(_ html: String) throws(ParseError) -> [BinAddress] {
        guard let select = html.firstMatch(of: /(?is)<select\b[^>]*\bid\s*=\s*"address"[^>]*>(.*?)<\/select>/) else {
            let isNoResultsPage = html.contains("name=\"postcode\"")
                && (html.contains("govuk-error-summary") || html.contains("govuk-error-message"))
            if isNoResultsPage { return [] }
            throw .addressSelectMissing
        }

        var seen = Set<String>()
        var addresses: [BinAddress] = []
        for option in select.output.1.matches(of: /(?is)<option\b[^>]*\bvalue\s*=\s*"([^"]*)"[^>]*>(.*?)<\/option>/) {
            let propertyId = String(option.output.1).trimmingCharacters(in: .whitespaces)
            let text = decodeEntities(String(option.output.2).replacing(/<[^>]+>/, with: ""))
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !propertyId.isEmpty, propertyId.allSatisfy(\.isASCIIDigit), !text.isEmpty,
                  seen.insert(propertyId).inserted
            else { continue }
            addresses.append(BinAddress(propertyId: propertyId, address: text))
        }
        guard !addresses.isEmpty else { throw .noNumericOptions }

        // Upstream order isn't guaranteed; sort naturally ("Flat 2" before "Flat 10").
        return addresses.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "rsquo": "\u{2019}", "lsquo": "\u{2018}", "ndash": "\u{2013}", "mdash": "\u{2014}"]
        return text.replacing(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);/) { match in
            let entity = String(match.output.1)
            if entity.hasPrefix("#") {
                let isHex = entity.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = isHex ? entity.dropFirst(2) : entity.dropFirst()
                if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
                return String(match.output.0)
            }
            return named[entity] ?? String(match.output.0)
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

extension URLError {
    var isConnectivityFailure: Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
         .timedOut, .dataNotAllowed, .internationalRoamingOff].contains(code)
    }
}
