import Foundation

// Used while unlocked. State and sensitive authorized replay material are
// sealed using a separate device-local Keychain key, without cloud sync.
import Security
import CryptoKit
public actor LocalStore {
    public struct State: Codable, Sendable {
        public var chains: [Chain] = Chain.defaults
        public var tokens: [Token] = []
        public var activities: [Activity] = []
        public var moneroRestoreHeights: [String: UInt64]?
        public var preferences: WalletPreferences?
        public var assetBalances: [AssetBalanceSnapshot]?
        public var marketPrices: [MarketPriceSnapshot]?
        public init() {}
    }
    private let url: URL
    private let service = "app.veilwallet.local-data"
    private let testingKey: SymmetricKey?
    public init(url: URL) { self.url = url; testingKey = nil }
    init(url: URL, testingKey: Data) throws {
        guard testingKey.count == 32 else { throw WalletError.invalid(L("message.the_test_key_must_be_32_bytes")) }; self.url = url; self.testingKey = SymmetricKey(data: testingKey)
    }
    public func load() throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        var state = try JSONDecoder().decode(State.self, from: AES.GCM.open(box, using: localKey(), authenticating: Data(service.utf8)))
        state.chains = NetworkCatalog.mergeDefaults(into: state.chains)
        return state
    }
    public func save(_ state: State) throws {
        let sealed = try AES.GCM.seal(JSONEncoder().encode(state), using: localKey(), authenticating: Data(service.utf8))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try sealed.combined!.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func transactionURL(_ id: UUID) -> URL { url.deletingLastPathComponent().appendingPathComponent("Transactions", isDirectory: true).appendingPathComponent(id.uuidString + ".sealed") }
    public func saveTransaction(_ archive: TransactionArchive) throws {
        try archive.validate()
        let path = transactionURL(archive.activityID), bytes = try JSONEncoder().encode(archive)
        guard bytes.count <= 4 * 1024 * 1024 else { throw WalletError.invalid(L("message.the_transaction_archive_exceeds_the_local_limit")) }
        let box = try AES.GCM.seal(bytes, using: localKey(), authenticating: Data((service + ":transaction:" + archive.activityID.uuidString).utf8))
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try box.combined!.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func transaction(id: UUID) throws -> TransactionArchive {
        let path = transactionURL(id)
        guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw WalletError.invalid(L("message.the_local_transaction_archive_is_too_large")) }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: path))
        let bytes = try AES.GCM.open(box, using: localKey(), authenticating: Data((service + ":transaction:" + id.uuidString).utf8))
        let archive = try JSONDecoder().decode(TransactionArchive.self, from: bytes)
        guard archive.activityID == id else { throw WalletError.invalid(L("message.transaction_archive_id_mismatch")) }; try archive.validate(); return archive
    }
    public func recoverTransactions(into activities: [Activity]) throws -> [Activity] {
        let folder = url.deletingLastPathComponent().appendingPathComponent("Transactions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return activities }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard files.count <= 10_000 else { throw WalletError.invalid(L("message.the_local_transaction_archive_exceeds_10_000_entries_review_the")) }
        var result = activities
        for file in files where file.pathExtension == "sealed" {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true, let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw WalletError.invalid(L("message.invalid_transaction_archive_path")) }
            let archive = try transaction(id: id)
            guard let saved = archive.activity else { continue }
            if let index = result.firstIndex(where: { $0.id == id }) {
                guard result[index].hash.lowercased() == saved.hash.lowercased() else { throw WalletError.invalid(L("message.transaction_journal_id_conflict")) }
                if (saved.transaction?.broadcastAttempts ?? 0) > (result[index].transaction?.broadcastAttempts ?? 0) || (saved.phase == .discarded && result[index].transaction?.broadcastAttempts == 0) { result[index] = saved }
            } else { result.append(saved) }
        }
        return result
    }
    public func removeUnbroadcastArchive(id: UUID) throws {
        var archive = try transaction(id: id)
        guard archive.activity?.transaction?.broadcastAttempts == 0 else { throw WalletError.invalid(L("message.a_transaction_with_a_broadcast_attempt_cannot_be_deleted_as")) }
        try archive.discardSignature(); try saveTransaction(archive)
    }
    private func treeURL(_ poolID: String) throws -> URL {
        guard PrivacyPoolCatalog.find(poolID) != nil else { throw WalletError.invalid(L("message.unknown_privacy_pool")) }
        return url.deletingLastPathComponent().appendingPathComponent("PrivacyTrees", isDirectory: true).appendingPathComponent(poolID + ".sealed")
    }
    public func loadPrivacyTree(poolID: String) throws -> PrivacyTreeSnapshot? {
        let path = try treeURL(poolID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 128 * 1024 * 1024 else { throw WalletError.invalid(L("message.the_deposit_tree_cache_is_too_large")) }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: path))
        let data = try AES.GCM.open(box, using: localKey(), authenticating: Data((service + ":tree:" + poolID).utf8))
        let tree = try JSONDecoder().decode(PrivacyTreeSnapshot.self, from: data)
        guard tree.poolID == poolID else { throw WalletError.invalid(L("message.deposit_tree_cache_pool_mismatch")) }; return tree
    }
    public func savePrivacyTree(_ tree: PrivacyTreeSnapshot) throws {
        let path = try treeURL(tree.poolID)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(tree), using: localKey(), authenticating: Data((service + ":tree:" + tree.poolID).utf8))
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try sealed.combined!.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func resetPrivacyTree(poolID: String) throws {
        let path = try treeURL(poolID)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    private func localKey() throws -> SymmetricKey {
        if let testingKey { return testingKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "metadata", kSecAttrSynchronizable as String: false]
        var request = query; request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw WalletError.invalid(L("message.local_keychain_unavailable_0", status)) }
        // Never replace a missing key when ciphertext already exists.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw WalletError.invalid(L("message.the_local_metadata_key_is_missing_restore_the_local_keychain")) }
        let data = try Data.secureRandom(count: 32)
        var add = query; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw WalletError.invalid(L("message.unable_to_save_the_local_keychain_key")) }
        return SymmetricKey(data: data)
    }
}
