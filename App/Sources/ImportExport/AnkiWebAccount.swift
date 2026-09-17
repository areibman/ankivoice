import Foundation
import Observation

/// Optional AnkiWeb login used only to lift AnkiWeb's anonymous
/// download cap. The password lives in the Keychain; the session cookie in
/// the app's cookie jar. Nothing is synced or uploaded.
@MainActor
@Observable
final class AnkiWebAccount {
    private static let usernameKey = "ankiweb.username"
    private static let keychainService = "com.hyperbox.ankivoice.ankiweb"

    private(set) var username: String?
    private let client: AnkiWebClient
    private let defaults: UserDefaults

    init(client: AnkiWebClient = AnkiWebClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.username = defaults.string(forKey: Self.usernameKey)
    }

    var isSignedIn: Bool { username != nil }

    func signIn(username rawUsername: String, password: String) async throws {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            throw AnkiWebClient.ClientError.loginFailed
        }
        try await client.signIn(username: username, password: password)
        if let previous = self.username, previous != username {
            KeychainStore.delete(service: Self.keychainService, account: previous)
        }
        try KeychainStore.save(password, service: Self.keychainService, account: username)
        defaults.set(username, forKey: Self.usernameKey)
        self.username = username
    }

    func signOut() {
        if let username {
            KeychainStore.delete(service: Self.keychainService, account: username)
        }
        defaults.removeObject(forKey: Self.usernameKey)
        client.signOut()
        username = nil
    }

    /// Re-establishes the session cookie from stored credentials, e.g. after
    /// AnkiWeb expired it. Returns false when there's nothing to restore.
    func restoreSession() async -> Bool {
        guard let username,
              let password = KeychainStore.read(service: Self.keychainService, account: username) else {
            return false
        }
        do {
            try await client.signIn(username: username, password: password)
            return true
        } catch {
            return false
        }
    }
}
