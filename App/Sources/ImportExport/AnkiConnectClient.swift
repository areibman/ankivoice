import Foundation

/// Client for the AnkiConnect add-on (https://git.sr.ht/~foosoft/anki-connect).
///
/// AnkiConnect runs an HTTP server inside Anki desktop (port 8765 by default).
/// Every request is a JSON object `{action, version, params, key}` and every
/// response is `{result, error}`. Only the actions the importer needs are
/// wrapped here.
///
/// To reach Anki from an iPhone the add-on must be bound to the LAN: in Anki,
/// Tools ▸ Add-ons ▸ AnkiConnect ▸ Config, set `"webBindAddress": "0.0.0.0"`
/// and restart Anki. Native requests carry no `Origin` header, so the
/// `webCorsOriginList` browser allow-list does not apply.
public struct AnkiConnectClient: Sendable {

    public static let defaultPort = 8765
    public static let apiVersion = 6

    public enum ClientError: LocalizedError, Equatable, Sendable {
        case invalidEndpoint
        case unreachable(String)
        case badResponse
        case apiError(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Enter the IP address or hostname of the computer running Anki."
            case .unreachable(let detail):
                return "Couldn't reach Anki. Make sure Anki is open with AnkiConnect installed, both devices are on the same Wi‑Fi, and AnkiConnect's webBindAddress is set to 0.0.0.0. (\(detail))"
            case .badResponse:
                return "Anki replied with something that wasn't an AnkiConnect response. Check the address and port."
            case .apiError(let message):
                if message.lowercased().contains("valid api key") {
                    return "AnkiConnect requires an API key. Enter the key from the add-on's config."
                }
                return "AnkiConnect error: \(message)"
            case .unsupportedVersion(let version):
                return "AnkiConnect version \(version) is too old. Update the add-on in Anki."
            }
        }
    }

    // MARK: Response shapes

    public struct DeckStats: Decodable, Sendable, Equatable {
        public let deckID: Int64
        public let name: String
        public let newCount: Int
        public let learnCount: Int
        public let reviewCount: Int
        public let totalInDeck: Int

        enum CodingKeys: String, CodingKey {
            case deckID = "deck_id", name
            case newCount = "new_count", learnCount = "learn_count"
            case reviewCount = "review_count", totalInDeck = "total_in_deck"
        }
    }

    public struct FieldValue: Decodable, Sendable, Equatable {
        public let value: String
        public let order: Int
    }

    public struct CardInfo: Decodable, Sendable, Equatable {
        public let cardId: Int64
        public let note: Int64
        public let deckName: String
        public let modelName: String
        public let ord: Int
        public let type: Int
        public let queue: Int
        public let due: Double
        public let interval: Int
        public let reps: Int
        public let lapses: Int
        public let mod: Double
    }

    public struct NoteInfo: Decodable, Sendable, Equatable {
        public let noteId: Int64
        public let modelName: String
        public let tags: [String]
        public let fields: [String: FieldValue]

        /// Field values in template order.
        public var orderedFieldValues: [String] {
            fields.values.sorted { $0.order < $1.order }.map(\.value)
        }
    }

    public struct ReviewEntry: Decodable, Sendable, Equatable {
        /// Review time in epoch milliseconds (also the revlog id).
        public let id: Int64
        /// Button pressed: 1 again … 4 easy (0 for manual/reset entries).
        public let ease: Int
        /// Duration in milliseconds.
        public let time: Int
        /// 0 learn, 1 review, 2 relearn, 3 filtered/early, 4 manual, 5 rescheduled.
        public let type: Int
    }

    public struct ModelTemplate: Decodable, Sendable, Equatable {
        public let name: String?
        public let ord: Int?
        public let qfmt: String?
        public let afmt: String?
    }

    public struct ModelField: Decodable, Sendable, Equatable {
        public let name: String
        public let ord: Int?
    }

    public struct Model: Decodable, Sendable, Equatable {
        public let id: Int64
        public let name: String
        public let type: Int?
        public let flds: [ModelField]?
        public let tmpls: [ModelTemplate]?
        public let css: String?
    }

    // MARK: Configuration

    public let endpoint: URL
    public let apiKey: String?
    private let session: URLSession

    /// Builds a client for `host:port`. `host` may be a bare IP/hostname or a
    /// pasted `http://host:port` URL.
    public init?(host: String, port: Int = AnkiConnectClient.defaultPort, apiKey: String? = nil, session: URLSession? = nil) {
        guard let endpoint = Self.endpoint(host: host, port: port) else { return nil }
        self.endpoint = endpoint
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 300
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    static func endpoint(host: String, port: Int) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            // Full URL pasted: honour its scheme/host/port, ignore the path.
            guard let url = URL(string: trimmed), let h = url.host else { return nil }
            var comps = URLComponents()
            comps.scheme = url.scheme ?? "http"
            comps.host = h
            comps.port = url.port ?? port
            comps.path = "/"
            return comps.url
        }
        // Strip any trailing path.
        if let slash = trimmed.firstIndex(of: "/") { trimmed = String(trimmed[..<slash]) }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.path = "/"
        // host:port form (IPv6 in brackets supported by URLComponents).
        if let colon = trimmed.lastIndex(of: ":"), !trimmed.hasPrefix("["),
           trimmed.filter({ $0 == ":" }).count == 1,
           let p = Int(trimmed[trimmed.index(after: colon)...]) {
            comps.host = String(trimmed[..<colon])
            comps.port = p
        } else {
            comps.host = trimmed
            comps.port = port
        }
        guard let h = comps.host, !h.isEmpty else { return nil }
        return comps.url
    }

    // MARK: Actions

    /// Round-trips `version` and validates the reply. Returns the API version.
    public func ping() async throws -> Int {
        let version: Int = try await invoke("version")
        guard version >= 5 else { throw ClientError.unsupportedVersion(version) }
        return version
    }

    public func deckNamesAndIDs() async throws -> [String: Int64] {
        try await invoke("deckNamesAndIds")
    }

    public func deckStats(names: [String]) async throws -> [DeckStats] {
        guard !names.isEmpty else { return [] }
        let byID: [String: DeckStats] = try await invoke("getDeckStats", params: ["decks": names])
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func findCards(query: String) async throws -> [Int64] {
        try await invoke("findCards", params: ["query": query])
    }

    public func cardsInfo(ids: [Int64]) async throws -> [CardInfo] {
        guard !ids.isEmpty else { return [] }
        return try await invoke("cardsInfo", params: ["cards": ids])
    }

    public func notesInfo(ids: [Int64]) async throws -> [NoteInfo] {
        guard !ids.isEmpty else { return [] }
        return try await invoke("notesInfo", params: ["notes": ids])
    }

    public func reviewsOfCards(ids: [Int64]) async throws -> [Int64: [ReviewEntry]] {
        guard !ids.isEmpty else { return [:] }
        let keyed: [String: [ReviewEntry]] = try await invoke(
            "getReviewsOfCards", params: ["cards": ids.map(String.init)]
        )
        var result: [Int64: [ReviewEntry]] = [:]
        for (key, entries) in keyed {
            guard let id = Int64(key) else { continue }
            result[id] = entries.sorted { $0.id < $1.id }
        }
        return result
    }

    public func findModels(names: [String]) async throws -> [Model] {
        guard !names.isEmpty else { return [] }
        return try await invoke("findModelsByName", params: ["modelNames": names])
    }

    /// Returns the file bytes, or nil when Anki has no such media file.
    public func retrieveMediaFile(named filename: String) async throws -> Data? {
        let raw: AnyJSON = try await invoke("retrieveMediaFile", params: ["filename": filename])
        switch raw {
        case .string(let base64):
            return Data(base64Encoded: base64)
        default:
            return nil
        }
    }

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }

    func invoke<T: Decodable>(_ action: String, params: [String: Any]? = nil) async throws -> T {
        var body: [String: Any] = ["action": action, "version": Self.apiVersion]
        if let params { body["params"] = params }
        if let apiKey { body["key"] = apiKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw ClientError.badResponse
        }
        if let message = envelope.error, !message.isEmpty {
            throw ClientError.apiError(message)
        }
        guard let result = envelope.result else {
            // `null` result with no error: valid for a few actions, but the
            // typed callers here always expect a value.
            if let empty = try? JSONDecoder().decode(T.self, from: Data("null".utf8)) {
                return empty
            }
            throw ClientError.badResponse
        }
        return result
    }
}

/// Minimal dynamic JSON value for results whose type varies (`false` | string).
enum AnyJSON: Decodable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        self = .other
    }
}
