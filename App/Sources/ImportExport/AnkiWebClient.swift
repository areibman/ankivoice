import Foundation

/// Client for AnkiWeb's shared-deck service.
///
/// AnkiWeb is a single-page app; the HTML pages contain no deck data. The
/// site itself talks to `/svc/shared/*` with protobuf bodies, which is what
/// this client mirrors:
///
/// - `GET /svc/shared/list-decks?search=…`           → `ListDecksResponse`
/// - `GET /svc/shared/item-info?sharedId=…`          → `ItemInfoResponse`
/// - `GET /svc/shared/download-deck/<id>?t=<key>`    → the `.apkg` bytes
///
/// The download key comes from `item-info` and is short-lived, so downloads
/// always fetch fresh item info first.
public struct AnkiWebClient: Sendable {

    public struct DeckSummary: Identifiable, Hashable, Sendable {
        public let id: Int
        public let title: String
        public let thumbsUp: Int
        public let thumbsDown: Int
        public let modified: Date?
        public let notes: Int
        public let audio: Int
        public let images: Int

        /// Lower bound of the Wilson score interval — the ranking AnkiWeb
        /// itself uses for its "Ratings" sort, so results match the website.
        public var ratingScore: Double {
            let total = Double(thumbsUp + thumbsDown)
            guard total > 0 else { return 0 }
            let z = 1.96
            let p = Double(thumbsUp) / total
            let numerator = p + z * z / (2 * total) - z * sqrt((p * (1 - p) + z * z / (4 * total)) / total)
            return numerator / (1 + z * z / total)
        }

        public var pageURL: URL {
            URL(string: "https://ankiweb.net/shared/info/\(id)")!
        }
    }

    public struct SampleNote: Hashable, Sendable {
        public struct Field: Hashable, Sendable {
            public let name: String
            public let value: String
        }

        public let fields: [Field]

        /// Field values in note-type order, with empty values dropped.
        public var values: [String] {
            fields.map(\.value).filter { !$0.isEmpty }
        }
    }

    public struct DeckInfo: Hashable, Sendable {
        public let id: Int
        public let title: String
        public let tags: [String]
        /// Compressed package size in bytes.
        public let size: Int
        public let lastUpdated: Date?
        /// HTML description as authored on AnkiWeb.
        public let descriptionHTML: String
        public let notes: Int
        public let audio: Int
        public let images: Int
        public let thumbsUp: Int
        public let thumbsDown: Int
        public let sampleNotes: [SampleNote]
        public let downloadKey: String
        public let originalDeckName: String

        public var pageURL: URL {
            URL(string: "https://ankiweb.net/shared/info/\(id)")!
        }

        /// Description with HTML stripped, for compact display.
        public var descriptionText: String {
            Self.plainText(fromHTML: descriptionHTML)
        }

        static func plainText(fromHTML html: String) -> String {
            var text = html
            for br in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>"] {
                text = text.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
            }
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\[sound:[^\\]]*\\]", with: "", options: .regularExpression)
            let entities: [String: String] = [
                "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            ]
            for (entity, replacement) in entities {
                text = text.replacingOccurrences(of: entity, with: replacement)
            }
            text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public enum ItemInfo: Sendable {
        case deck(DeckInfo)
        /// The shared item is an Anki add-on (e.g. AnkiConnect), not a deck.
        case addon(title: String)
        case missing
        case accessDenied
    }

    public enum ClientError: LocalizedError, Equatable {
        case badStatus(Int)
        case rateLimited
        /// AnkiWeb caps anonymous deck downloads; signing in lifts the cap.
        case downloadLimitReached(signedIn: Bool)
        /// AnkiWeb also caps anonymous searches ("Please log in to perform
        /// more searches."); signing in lifts that cap too.
        case searchLimitReached(signedIn: Bool)
        case malformedResponse
        case tooManyMatches
        case notADeck(String)
        case notFound
        case accessDenied
        case invalidReference(String)
        case unknownAccount
        case wrongPassword
        case loginFailed

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "AnkiWeb returned HTTP \(code)."
            case .rateLimited: return "AnkiWeb is limiting requests right now. Wait a minute and try again."
            case .downloadLimitReached(let signedIn):
                return signedIn
                    ? "AnkiWeb's download limit for your account has been reached. Try again later."
                    : "AnkiWeb limits how many decks visitors can download. Sign in to your AnkiWeb account to keep importing."
            case .searchLimitReached(let signedIn):
                return signedIn
                    ? "AnkiWeb's search limit for your account has been reached. Try again later."
                    : "AnkiWeb limits how many searches visitors can run. Sign in to your AnkiWeb account to keep searching."
            case .malformedResponse: return "AnkiWeb sent a response the app couldn't read."
            case .tooManyMatches: return "Too many matches. Try a more specific search."
            case .notADeck(let title): return "“\(title)” is an Anki add-on, not a deck. Add-ons can't be imported."
            case .notFound: return "That shared deck no longer exists on AnkiWeb."
            case .accessDenied: return "AnkiWeb refused access to that deck."
            case .invalidReference(let text): return "“\(text)” isn't an AnkiWeb deck link or ID."
            case .unknownAccount: return "No AnkiWeb account was found with that email address."
            case .wrongPassword: return "That password doesn't match the AnkiWeb account."
            case .loginFailed: return "AnkiWeb didn't accept the sign-in. Try again in a moment."
            }
        }
    }

    private let base = URL(string: "https://ankiweb.net")!
    private let userBase = URL(string: "https://ankiuser.net")!
    private let session: URLSession

    /// Uses the shared session so the AnkiWeb login cookie is stored in the
    /// app's persistent cookie jar and reused by download tasks.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Account

    /// Whether the persistent cookie jar holds an AnkiWeb session cookie.
    public var hasSessionCookie: Bool {
        let storage = session.configuration.httpCookieStorage ?? .shared
        return !(storage.cookies(for: base) ?? []).isEmpty
    }

    /// Signs in with AnkiWeb credentials. On success the session cookie is
    /// kept in the cookie jar, so subsequent downloads count against the
    /// account's (much higher) limit instead of the anonymous one.
    public func signIn(username: String, password: String) async throws {
        var body = Data()
        ProtobufWriter.appendString(username, field: 1, to: &body)
        ProtobufWriter.appendString(password, field: 2, to: &body)
        let data = try await post(base.appendingPathComponent("svc/account/login"), body: body)
        let response = try Self.decode(data)
        // LoginResponse { LoginResponseStatus status = 1; string token = 2; }
        switch response.int(1) ?? 0 {
        case 1:
            guard let token = response.string(2), !token.isEmpty else { throw ClientError.loginFailed }
            try await exchangeLoginToken(token)
        case 2: throw ClientError.unknownAccount
        case 3: throw ClientError.wrongPassword
        default: throw ClientError.loginFailed
        }
    }

    /// The website completes login by visiting ankiuser.net with the token,
    /// which sets session cookies and redirects back to ankiweb.net.
    private func exchangeLoginToken(_ token: String) async throws {
        var components = URLComponents(url: userBase.appendingPathComponent("account/ankiuser-login"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw ClientError.loginFailed
        }
    }

    /// Drops AnkiWeb session cookies.
    public func signOut() {
        let storage = session.configuration.httpCookieStorage ?? .shared
        for url in [base, userBase] {
            for cookie in storage.cookies(for: url) ?? [] {
                storage.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Search

    /// Searches shared decks. Results come back unsorted; callers sort.
    public func searchDecks(_ query: String) async throws -> [DeckSummary] {
        var components = URLComponents(url: base.appendingPathComponent("svc/shared/list-decks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "search", value: query)]
        let data = try await get(components.url!)
        let message = try Self.decode(data)
        return message.messages(1).compactMap(Self.summary)
    }

    static func summary(_ row: ProtobufMessage) -> DeckSummary? {
        guard let id = row.int(1), let title = row.string(2) else { return nil }
        return DeckSummary(
            id: id,
            title: title,
            thumbsUp: row.int(3) ?? 0,
            thumbsDown: row.int(4) ?? 0,
            modified: row.int(5).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            notes: row.int(6) ?? 0,
            audio: row.int(7) ?? 0,
            images: row.int(8) ?? 0
        )
    }

    // MARK: - Item info

    public func itemInfo(id: Int) async throws -> ItemInfo {
        var components = URLComponents(url: base.appendingPathComponent("svc/shared/item-info"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sharedId", value: String(id))]
        let data = try await get(components.url!)
        return try Self.itemInfo(id: id, from: data)
    }

    static func itemInfo(id: Int, from data: Data) throws -> ItemInfo {
        let message = try decode(data)
        if message.has(2) { return .missing }
        if message.has(3) { return .accessDenied }
        guard let available = message.message(1) else { throw ClientError.malformedResponse }
        let title = available.string(5) ?? "Untitled"
        guard let deck = available.message(10) else {
            return .addon(title: title)
        }
        let tags = (available.string(6) ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty }
        // SampleNote { repeated Field fields = 1; }  Field { string name = 1; string value = 2; }
        let samples = deck.messages(4).map { sample in
            SampleNote(fields: sample.messages(1).map { field in
                SampleNote.Field(name: field.string(1) ?? "", value: field.string(2) ?? "")
            })
        }
        return .deck(
            DeckInfo(
                id: id,
                title: title,
                tags: tags,
                size: available.int(7) ?? 0,
                lastUpdated: available.int(8).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                descriptionHTML: available.string(9) ?? "",
                notes: deck.int(1) ?? 0,
                audio: deck.int(2) ?? 0,
                images: deck.int(3) ?? 0,
                thumbsUp: available.int(18) ?? 0,
                thumbsDown: available.int(19) ?? 0,
                sampleNotes: samples,
                downloadKey: deck.string(5) ?? "",
                originalDeckName: available.string(20) ?? ""
            )
        )
    }

    /// Fetches item info and requires it to be a deck.
    public func deckInfo(id: Int) async throws -> DeckInfo {
        switch try await itemInfo(id: id) {
        case .deck(let info): return info
        case .addon(let title): throw ClientError.notADeck(title)
        case .missing: throw ClientError.notFound
        case .accessDenied: throw ClientError.accessDenied
        }
    }

    // MARK: - Download

    /// Downloads the `.apkg` for a deck to a temporary file, reporting
    /// progress as a 0…1 fraction (nil while the size is unknown).
    public func downloadDeck(
        _ info: DeckInfo,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        var components = URLComponents(url: base.appendingPathComponent("svc/shared/download-deck/\(info.id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: info.downloadKey)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 300

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ankiweb-\(info.id)-\(UUID().uuidString).apkg")
        progress(nil)
        try await FileDownloader.download(request, to: destination, progress: progress)
        progress(1)
        return destination
    }

    // MARK: - References

    /// Parses "https://ankiweb.net/shared/info/2055492159", "/shared/info/…"
    /// or a bare numeric ID into a shared-item ID.
    public static func sharedID(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(trimmed), id > 0 { return id }
        guard let range = trimmed.range(of: #"shared/(?:info|download)/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = trimmed[range]
        let digits = match.split(separator: "/").last.map(String.init) ?? ""
        return Int(digits)
    }

    // MARK: - Transport

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func post(_ url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, signedIn: hasSessionCookie)
        }
        return data
    }

    /// Maps AnkiWeb's plain-text error bodies onto typed errors.
    ///
    /// Known 429 bodies: "Please log in to perform more searches." and
    /// "Please log in to download more decks."
    static func error(status: Int, body: Data?, signedIn: Bool) -> ClientError {
        let text = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        switch status {
        case 429 where text.localizedCaseInsensitiveContains("log in") && text.localizedCaseInsensitiveContains("search"):
            return .searchLimitReached(signedIn: signedIn)
        case 429 where text.localizedCaseInsensitiveContains("log in"):
            return .downloadLimitReached(signedIn: signedIn)
        case 429:
            return .rateLimited
        case 400, 413:
            return text.localizedCaseInsensitiveContains("too many") ? .tooManyMatches : .badStatus(status)
        default:
            return .badStatus(status)
        }
    }

    static func decode(_ data: Data) throws -> ProtobufMessage {
        do {
            return try ProtobufMessage(data: data)
        } catch {
            throw ClientError.malformedResponse
        }
    }
}

/// Progress-reporting file download built on a download task, so large
/// packages stream to disk instead of memory.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReported = -1.0
    private var session: URLSession?

    private init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let downloader = FileDownloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        downloader.session = session
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                downloader.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.01 {
            lastReported = fraction
            progress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Error bodies are short plain text ("Please log in to download more decks.").
                let body = (try? FileHandle(forReadingFrom: location))?.readData(ofLength: 4096)
                let signedIn = !(session.configuration.httpCookieStorage?.cookies(for: http.url ?? location) ?? []).isEmpty
                throw AnkiWebClient.error(status: http.statusCode, body: body, signedIn: signedIn)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let continuation {
            continuation.resume(throwing: error)
            self.continuation = nil
        }
    }
}
