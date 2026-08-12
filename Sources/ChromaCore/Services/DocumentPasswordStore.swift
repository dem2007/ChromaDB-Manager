import Foundation

/// Passwords for individual protected documents.
///
/// In the Keychain and nowhere else — rule 7 of Приложение 5. Not in
/// `config.json`, not in the manifest, not in the logs, and not in the source's
/// settings, where an export of the configuration would carry it to another
/// machine (`SettingsTransfer` exports sources).
///
/// Keyed by source **and** relative path: the same file name under two sources
/// is two files, and a password given for one is not an answer for the other.
public struct DocumentPasswordStore {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore(service: DocumentPasswordStore.service)) {
        self.keychain = keychain
    }

    public static let service = "io.github.chromadbmanager.document-passwords"

    /// The account name is a hash rather than the path itself: the Keychain item
    /// list is readable in Keychain Access, and a user's folder structure is not
    /// something this app should publish there.
    static func account(sourceID: UUID, relativePath: String) -> String {
        let digest = SourceSyncService.contentHash(of: "\(sourceID.uuidString)\u{0}\(relativePath)")
        return String(digest.prefix(32))
    }

    public func password(sourceID: UUID, relativePath: String) -> String? {
        let value = try? keychain.token(for: Self.account(sourceID: sourceID, relativePath: relativePath))
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public func has(sourceID: UUID, relativePath: String) -> Bool {
        password(sourceID: sourceID, relativePath: relativePath) != nil
    }

    /// An empty password removes the item — the same way a cleared token field
    /// clears a server token.
    public func set(_ password: String, sourceID: UUID, relativePath: String) throws {
        try keychain.set(password, for: Self.account(sourceID: sourceID, relativePath: relativePath))
    }

    public func remove(sourceID: UUID, relativePath: String) {
        try? keychain.remove(account: Self.account(sourceID: sourceID, relativePath: relativePath))
    }
}
