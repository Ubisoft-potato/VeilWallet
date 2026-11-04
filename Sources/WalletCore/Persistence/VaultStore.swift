import Foundation
import CryptoKit

public actor VaultStore {
    private struct Envelope: Codable {
        let version: Int
        let rounds: UInt32
        let salt: Data
        let sealed: Data
    }
    public static let rounds: UInt32 = 600_000
    private let url: URL
    private var contents: VaultContents?
    private var key: SymmetricKey?
    private var salt: Data?
    private var sessionID = UUID()
    public init(url: URL) { self.url = url }
    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VeilWallet", isDirectory: true)
    }
    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func create(password: String) throws {
        guard !exists() else { throw WalletError.invalid(L("message.a_vault_already_exists_unlock_it")) }
        guard password.count >= 12 else { throw WalletError.invalid(L("message.the_password_must_contain_at_least_12_characters")) }
        let salt = try Data.secureRandom(count: 32)
        let key = try derive(password: password, salt: salt)
        self.salt = salt; self.key = key; contents = VaultContents()
        sessionID = UUID()
        do { try persist() } catch { lock(); throw error }
    }
    public func unlock(password: String) throws -> [WalletSummary] {
        var (restored, envelope, key) = try open(password: password)
        var migrated = false
        for index in restored.wallets.indices where restored.wallets[index].summary.kind == .mnemonic {
            let record = restored.wallets[index]
            let existing = record.summary.allAccounts
            let known = Set(existing.map(\.profileID))
            let missing = AccountProfile.derivable.filter { !known.contains($0.id) }
            if !missing.isEmpty {
                let accountIndex = record.summary.accountIndex ?? UInt32(record.summary.path?.split(separator: "/").last ?? "0") ?? 0
                let added = try MultichainCrypto.deriveAccounts(phrase: record.material, passphrase: record.passphrase, index: accountIndex, profiles: missing)
                restored.wallets[index].summary.accounts = existing + added
                restored.wallets[index].summary.accountIndex = accountIndex; migrated = true
            }
        }
        self.contents = restored; self.salt = envelope.salt; self.key = key
        sessionID = UUID()
        if migrated { do { try persist() } catch { lock(); throw error } }
        return restored.wallets.map(\.summary)
    }
    public func lock() { contents = nil; key = nil; salt = nil; sessionID = UUID() }
    public func summaries() throws -> [WalletSummary] {
        guard let contents else { throw WalletError.locked }; return contents.wallets.map(\.summary)
    }
    public func privacyNotes() throws -> [PrivacyNoteSummary] {
        guard let contents else { throw WalletError.locked }; return (contents.privacyNotes ?? []).map(\.summary)
    }
    public func createPrivacyNote(poolID: String, walletID: UUID, password: String, runtime: PrivacyProofRuntime) async throws -> PrivacyNoteSummary {
        guard let contents, contents.wallets.contains(where: { $0.summary.id == walletID && $0.summary.canSign }), let pool = PrivacyPoolCatalog.find(poolID) else { throw WalletError.locked }
        _ = try open(password: password)
        let session = sessionID, material = try PrivacyNoteMaterial.create(pool: pool)
        let derived = try await runtime.derive(material)
        guard self.contents?.wallets.contains(where: { $0.summary.id == walletID }) == true, session == sessionID else { throw WalletError.locked }
        return try storePrivacyNote(material, commitment: derived.commitment, walletID: walletID)
    }
    public func importPrivacyNote(_ value: String, password: String, runtime: PrivacyProofRuntime) async throws -> PrivacyNoteSummary {
        guard contents != nil else { throw WalletError.locked }; _ = try open(password: password)
        let material = try PrivacyNoteMaterial(value), session = sessionID
        let derived = try await runtime.derive(material)
        guard contents != nil, session == sessionID else { throw WalletError.locked }
        return try storePrivacyNote(material, commitment: derived.commitment, walletID: nil)
    }
    private func storePrivacyNote(_ material: PrivacyNoteMaterial, commitment: String, walletID: UUID?) throws -> PrivacyNoteSummary {
        guard var updated = contents else { throw WalletError.locked }
        var notes = updated.privacyNotes ?? []
        if let existing = notes.first(where: { $0.material == material.canonical }) { return existing.summary }
        guard notes.count < 512 else { throw WalletError.invalid(L("message.the_vault_holds_at_most_512_privacy_notes_back_them")) }
        let summary = PrivacyNoteSummary(id: UUID(), walletID: walletID, poolID: material.pool.id, commitment: commitment, createdAt: Date())
        notes.append(.init(summary: summary, material: material.canonical)); updated.privacyNotes = notes
        let previous = contents; contents = updated
        do { try persist() } catch { contents = previous; throw error }; return summary
    }
    public func privacyNote(id: UUID, password: String) throws -> String {
        guard contents != nil else { throw WalletError.locked }
        let (disk, _, _) = try open(password: password)
        guard let note = disk.privacyNotes?.first(where: { $0.summary.id == id }) else { throw WalletError.invalid(L("message.privacy_note_not_found")) }
        return note.material
    }
    public func authorizePrivacy(_ intent: PrivacyTransactionIntent, password: String) throws {
        guard contents != nil else { throw WalletError.locked }
        let (disk, _, _) = try open(password: password)
        guard let note = disk.privacyNotes?.first(where: { $0.summary.id == intent.noteID }), note.summary.poolID == intent.poolID, note.summary.commitment == intent.commitment else { throw WalletError.invalid(L("message.the_privacy_transaction_does_not_match_the_vault_note")) }
        if intent.kind == .deposit, note.summary.depositHash != nil { throw WalletError.invalid(L("message.this_note_has_a_sending_record_verify_the_original_hash")) }
        if intent.kind == .withdraw, note.summary.withdrawalHash != nil { throw WalletError.invalid(L("message.this_note_has_a_withdrawal_record_verify_the_original_hash")) }
        if intent.kind == .withdraw, note.summary.depositSender?.lowercased() == intent.recipient.lowercased() { throw WalletError.invalid(L("message.use_a_separate_recipient_signing_account_withdrawing_directly_to_the")) }
    }
    public func recordPrivacyTransaction(_ intent: PrivacyTransactionIntent, hash: String, password: String) throws {
        try authorizePrivacy(intent, password: password)
        guard var updated = contents, let index = updated.privacyNotes?.firstIndex(where: { $0.summary.id == intent.noteID }), (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_privacy_transaction_hash")) }
        if intent.kind == .deposit { updated.privacyNotes?[index].summary.depositHash = hash; updated.privacyNotes?[index].summary.depositSender = intent.recipient } else { updated.privacyNotes?[index].summary.withdrawalHash = hash }
        updated.privacyNotes?[index].summary.attempts?.removeAll { $0.kind == intent.kind }
        let previous = contents; contents = updated
        do { try persist() } catch { contents = previous; throw error }
    }
    public func authorizeAccount(walletID: UUID, profileID: String, sender: String, password: String) throws {
        guard contents != nil else { throw WalletError.locked }; let (disk, _, _) = try open(password: password)
        guard let wallet = disk.wallets.first(where: { $0.summary.id == walletID }), wallet.summary.canSign,
              wallet.summary.allAccounts.contains(where: { $0.profileID == profileID && (profileID == "evm" ? $0.networkAddress.lowercased() == sender.lowercased() : $0.networkAddress == sender) }) else { throw WalletError.invalid(L("message.the_current_wallet_does_not_control_the_archived_transaction_s")) }
    }
    public func authorizePrivacyRetry(_ intent: PrivacyTransactionIntent, hash: String, password: String) throws {
        guard contents != nil else { throw WalletError.locked }; let (disk, _, _) = try open(password: password)
        guard let note = disk.privacyNotes?.first(where: { $0.summary.id == intent.noteID }), note.summary.poolID == intent.poolID, note.summary.commitment == intent.commitment else { throw WalletError.invalid(L("message.the_note_does_not_match_the_archived_transaction")) }
        let primary = intent.kind == .deposit ? note.summary.depositHash : note.summary.withdrawalHash
        guard primary?.lowercased() == hash.lowercased() || note.summary.attempts?.contains(where: { $0.kind == intent.kind && $0.hash.lowercased() == hash.lowercased() }) == true else { throw WalletError.invalid(L("message.this_transaction_hash_is_not_retained_in_the_note_check")) }
    }
    public func recordPrivacyReplacement(_ intent: PrivacyTransactionIntent, originalHash: String, newHash: String, cancellation: Bool, password: String) throws {
        try authorizePrivacyRetry(intent, hash: originalHash, password: password)
        guard var updated = contents, let index = updated.privacyNotes?.firstIndex(where: { $0.summary.id == intent.noteID }), (try? Data(strictHex: newHash).count) == 32 else { throw WalletError.invalid(L("message.invalid_replacement_note_sending_record")) }
        var attempts = updated.privacyNotes?[index].summary.attempts ?? []
        guard attempts.count < 128 else { throw WalletError.invalid(L("message.too_many_note_replacement_attempts_verify_the_on_chain_outcome")) }
        if !attempts.contains(where: { $0.hash == newHash }) { attempts.append(.init(hash: newHash, kind: intent.kind, cancellation: cancellation)) }
        updated.privacyNotes?[index].summary.attempts = attempts
        let previous = contents; contents = updated; do { try persist() } catch { contents = previous; throw error }
    }
    public func authorizeArchivedPrivacy(_ intent: PrivacyTransactionIntent, archive: TransactionArchive, password: String) throws {
        try archive.validate()
        guard let preview = archive.evm, archive.activity?.privacyNoteID == intent.noteID else { throw WalletError.invalid(L("message.the_archive_is_not_bound_to_the_current_note")) }
        if let ref = preview.replacement {
            try authorizePrivacyRetry(intent, hash: ref.hash, password: password)
            try recordPrivacyReplacement(intent, originalHash: ref.hash, newHash: archive.hash, cancellation: archive.activity?.transaction?.action == .cancel, password: password)
        } else {
            guard case .privacy(let saved, _) = preview.purpose, saved == intent else { throw WalletError.invalid(L("message.archived_note_intent_mismatch")) }
            let (disk, _, _) = try open(password: password)
            guard let note = disk.privacyNotes?.first(where: { $0.summary.id == intent.noteID }) else { throw WalletError.invalid(L("message.local_note_not_found")) }
            let primary = intent.kind == .deposit ? note.summary.depositHash : note.summary.withdrawalHash
            if primary == nil { try recordPrivacyTransaction(intent, hash: archive.hash, password: password) }
            else { try authorizePrivacyRetry(intent, hash: archive.hash, password: password) }
        }
    }
    public func reconcilePrivacy(_ intent: PrivacyTransactionIntent, winning: Activity, archive: TransactionArchive, password: String, rpc: RPCClient) async throws {
        try authorizePrivacyRetry(intent, hash: winning.hash, password: password); try archive.validate(); let session = sessionID
        guard winning.id == archive.activityID, let tx = archive.evm, winning.transaction?.groupID != nil, tx.transaction.chainID == rpc.chain.id else { throw WalletError.invalid(L("message.the_note_result_does_not_correspond_to_this_transaction_archive")) }
        let outcome = try await rpc.observe(activity: winning)
        guard [.confirmed, .failed].contains(outcome.phase), let success = outcome.executionSucceeded else { throw WalletError.invalid(L("message.the_note_operation_has_not_reached_the_confirmation_threshold")) }
        let cancellation = winning.transaction?.action == .cancel
        if cancellation {
            guard tx.transaction.to.lowercased() == tx.sender.lowercased(), tx.transaction.value == 0, tx.transaction.data.isEmpty else { throw WalletError.invalid(L("message.the_cancellation_is_not_a_zero_value_self_transfer")) }
        } else {
            guard case .privacy(let saved, _) = tx.purpose, saved.noteID == intent.noteID, saved.kind == intent.kind else { throw WalletError.invalid(L("message.the_confirmed_transaction_s_note_intent_does_not_match")) }
        }
        guard session == sessionID, var updated = contents, let index = updated.privacyNotes?.firstIndex(where: { $0.summary.id == intent.noteID }) else { throw WalletError.locked }
        try authorizePrivacyRetry(intent, hash: winning.hash, password: password)
        if intent.kind == .deposit {
            updated.privacyNotes?[index].summary.depositHash = success && !cancellation ? winning.hash : nil
            if !success || cancellation { updated.privacyNotes?[index].summary.depositSender = nil }
        } else { updated.privacyNotes?[index].summary.withdrawalHash = success && !cancellation ? winning.hash : nil }
        let previous = contents; contents = updated; do { try persist() } catch { contents = previous; throw error }
    }
    public func releaseUnbroadcastPrivacy(_ intent: PrivacyTransactionIntent, archive: TransactionArchive, password: String) throws {
        try archive.validate()
        guard archive.activity?.transaction?.broadcastAttempts == 0, archive.activity?.phase == .queued else { throw WalletError.invalid(L("message.only_local_queued_entries_with_no_broadcast_attempt_can_be")) }
        try authorizePrivacyRetry(intent, hash: archive.hash, password: password)
        guard var updated = contents, let index = updated.privacyNotes?.firstIndex(where: { $0.summary.id == intent.noteID }) else { throw WalletError.locked }
        if archive.evm?.replacement == nil {
            if intent.kind == .deposit { updated.privacyNotes?[index].summary.depositHash = nil; updated.privacyNotes?[index].summary.depositSender = nil }
            else { updated.privacyNotes?[index].summary.withdrawalHash = nil }
        }
        updated.privacyNotes?[index].summary.attempts?.removeAll { $0.hash == archive.hash }
        let previous = contents; contents = updated; do { try persist() } catch { contents = previous; throw error }
    }
    /// Clear only a canonically confirmed revert. A missing receipt or dropped
    /// broadcast response is never sufficient evidence to reuse a note.
    public func releaseFailedPrivacyTransaction(noteID: UUID, kind: PrivacyTransactionIntent.Kind, hash: String, password: String, rpc: RPCClient) async throws {
        guard let contents, let note = contents.privacyNotes?.first(where: { $0.summary.id == noteID }), note.summary.pool?.chainID == rpc.chain.id,
              (kind == .deposit ? note.summary.depositHash : note.summary.withdrawalHash)?.lowercased() == hash.lowercased() else { throw WalletError.invalid(L("message.the_note_s_sending_record_does_not_match_the_failed")) }
        _ = try open(password: password); let session = sessionID
        try await rpc.verifyChain()
        let receipt = try await rpc.call("eth_getTransactionReceipt", params: [.string(hash)])
        guard receipt["transactionHash"]?.string?.lowercased() == hash.lowercased(), receipt["to"]?.string?.lowercased() == note.summary.pool?.contract.lowercased(), receipt["status"] == .string("0x0"), let height = receipt["blockNumber"]?.string else { throw WalletError.invalid(L("message.only_confirmed_execution_failures_may_be_retried_unknown_status_retains")) }
        let block = try await rpc.call("eth_getBlockByNumber", params: [.string(height), .bool(false)])
        let latest = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        guard let tip = latest["number"]?.string, let canonical = block["hash"]?.string, (try? Data(strictHex: canonical).count) == 32, block["number"] == .string(height), receipt["blockHash"]?.string?.lowercased() == canonical.lowercased(),
              try Ethereum.decodeQuantity(tip) >= Ethereum.decodeQuantity(height) + (rpc.chain.id == 56 ? 14 : 11) else { throw WalletError.invalid(L("message.the_failed_transaction_lacks_enough_confirmations_or_was_reorganized")) }
        guard session == sessionID, var updated = self.contents, let index = updated.privacyNotes?.firstIndex(where: { $0.summary.id == noteID }),
              (kind == .deposit ? updated.privacyNotes?[index].summary.depositHash : updated.privacyNotes?[index].summary.withdrawalHash)?.lowercased() == hash.lowercased() else { throw WalletError.locked }
        _ = try open(password: password)
        if kind == .deposit { updated.privacyNotes?[index].summary.depositHash = nil; updated.privacyNotes?[index].summary.depositSender = nil }
        else { updated.privacyNotes?[index].summary.withdrawalHash = nil }
        let previous = self.contents; self.contents = updated
        do { try persist() } catch { self.contents = previous; throw error }
    }
    @discardableResult
    public func addMnemonic(name: String, phrase: String, passphrase: String = "", account: UInt32 = 0, overrides: [String: String] = [:]) throws -> WalletSummary {
        guard contents != nil else { throw WalletError.locked }
        let accounts = try MultichainCrypto.deriveAccounts(phrase: phrase, passphrase: passphrase, index: account, overrides: overrides)
        guard let primary = accounts.first(where: { $0.profileID == "evm" }) else { throw WalletError.invalid(L("message.missing_primary_account")) }
        let summary = WalletSummary(name: try validName(name), address: primary.address, kind: .mnemonic, path: primary.path, accounts: accounts, accountIndex: account)
        try append(WalletSecret(summary: summary, material: Mnemonic.normalize(phrase), passphrase: passphrase))
        return summary
    }
    @discardableResult
    public func addPrivateKey(name: String, hex: String) throws -> WalletSummary {
        try addPrivateKey(name: name, material: hex, profileID: "evm")
    }
    @discardableResult
    public func addPrivateKey(name: String, material: String, profileID: String) throws -> WalletSummary {
        guard contents != nil else { throw WalletError.locked }
        guard let profile = AccountProfile.find(profileID) else { throw WalletError.invalid(L("message.unsupported_private_key_network")) }
        let account = try MultichainCrypto.importPrivateKey(material, profile: profile)
        let summary = WalletSummary(name: try validName(name), address: account.address, kind: .privateKey, accounts: [account])
        try append(WalletSecret(summary: summary, material: material.trimmingCharacters(in: .whitespacesAndNewlines), passphrase: ""))
        return summary
    }
    @discardableResult
    public func addWatch(name: String, address: String) throws -> WalletSummary {
        try addWatch(name: name, address: address, profileID: "evm")
    }
    @discardableResult
    public func addWatch(name: String, address: String, profileID: String) throws -> WalletSummary {
        guard let profile = AccountProfile.find(profileID), MultichainCrypto.validateAddress(address, profile: profile) else { throw WalletError.invalid(L("message.the_address_format_or_checksum_does_not_match_the_selected")) }
        let value = profile.family == .evm ? Ethereum.checksumAddress(address) : address
        let needsBinding = profile.family == .eos || profile.family == .starknet
        let account = WalletAccount(profileID: profileID, address: value, boundAddress: needsBinding ? value : nil)
        let summary = WalletSummary(name: try validName(name), address: value, kind: .watch, accounts: [account])
        try append(WalletSecret(summary: summary, material: "", passphrase: "")); return summary
    }
    public func bindAccount(walletID: UUID, profileID: String, address: String) throws {
        guard var updated = contents else { throw WalletError.locked }
        guard let profile = AccountProfile.find(profileID), [.eos, .starknet].contains(profile.family), MultichainCrypto.validateAddress(address, profile: profile),
              let wallet = updated.wallets.firstIndex(where: { $0.summary.id == walletID }),
              var accounts = updated.wallets[wallet].summary.accounts,
              let account = accounts.firstIndex(where: { $0.profileID == profileID }) else { throw WalletError.invalid(L("message.invalid_on_chain_account_name_or_contract_address")) }
        accounts[account].boundAddress = address
        updated.wallets[wallet].summary.accounts = accounts
        let original = contents; contents = updated
        do { try persist() } catch { contents = original; throw error }
    }
    public func sign(transaction: EVMTransaction, walletID: UUID, password: String) throws -> Data {
        // Require a fresh password check for every signature, even while unlocked.
        guard contents != nil else { throw WalletError.locked }
        let (diskContents, _, _) = try open(password: password)
        guard let record = diskContents.wallets.first(where: { $0.summary.id == walletID }) else { throw WalletError.invalid(L("message.wallet_not_found")) }
        guard let account = record.summary.allAccounts.first(where: { $0.profileID == "evm" }) else { throw WalletError.invalid(L("message.this_wallet_has_no_imported_evm_private_key_cross_network")) }
        let key = try privateKey(record, account: account)
        guard try Ethereum.address(privateKey: key) == account.address else { throw WalletError.invalid(L("message.the_key_does_not_match_the_selected_address")) }
        return try transaction.signed(privateKey: key)
    }
    public func reveal(walletID: UUID, password: String) throws -> (material: String, passphrase: String) {
        guard contents != nil else { throw WalletError.locked }
        let (data, _, _) = try open(password: password)
        guard let record = data.wallets.first(where: { $0.summary.id == walletID }), record.summary.canSign else { throw WalletError.invalid(L("message.a_watch_only_wallet_has_no_private_key")) }
        return (record.material, record.passphrase)
    }
    public func signingPublicKey(walletID: UUID, profileID: String) throws -> Data {
        guard let contents, let record = contents.wallets.first(where: { $0.summary.id == walletID }), record.summary.canSign, let account = record.summary.allAccounts.first(where: { $0.profileID == profileID }), let profile = account.profile else { throw WalletError.invalid(L("message.this_account_does_not_provide_a_signing_public_key")) }
        let key = try privateKey(record, account: account)
        if profile.usesEd25519 { return try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation }
        guard profile.family == .cosmos else { throw WalletError.invalid(L("message.this_public_key_type_is_not_supported_yet")) }
        return try Secp256k1.publicKey(privateKey: key)
    }
    public func openMonero(runtime: MoneroRuntime, walletID: UUID, node: String, restoreHeight: UInt64) async throws {
        guard let contents, let record = contents.wallets.first(where: { $0.summary.id == walletID }), record.summary.canSign,
              let account = record.summary.allAccounts.first(where: { $0.profile?.family == .monero }), let profile = account.profile else { throw WalletError.invalid(L("message.xmr_scanning_requires_a_locally_held_seed_or_spend_key")) }
        let spend = try privateKey(record, account: account)
        let material = try MultichainCrypto.execute(.init(action: "address", profile: profile, key: spend.hexString))
        guard material.address == account.address, let view = material.viewKey else { throw WalletError.invalid(L("message.xmr_key_address_mismatch")) }
        // High-entropy cache encryption password; neither this nor the view/spend keys
        // are put in process arguments, logs, daemon requests or user metadata.
        let cachePassword = (Data("veil-monero-cache-v1".utf8) + spend).sha256Digest.hexString
        try await runtime.open(walletID: walletID, address: account.address, spendKey: spend.hexString, viewKey: view, cachePassword: cachePassword, node: node, restoreHeight: restoreHeight)
        guard self.contents != nil else { await runtime.stop(); throw WalletError.locked }
    }
    public func prepareMonero(runtime: MoneroRuntime, walletID: UUID, recipient: String, amount: String, password: String) async throws -> MoneroProposal {
        guard contents != nil else { throw WalletError.locked }
        let (disk, _, _) = try open(password: password)
        guard let record = disk.wallets.first(where: { $0.summary.id == walletID }), record.summary.canSign,
              let account = record.summary.allAccounts.first(where: { $0.profile?.family == .monero }) else { throw WalletError.invalid(L("message.this_wallet_cannot_sign_xmr_transactions")) }
        return try await runtime.prepareSigned(walletID: walletID, sender: account.address, recipient: recipient, amount: Ethereum.parseUnits(amount, decimals: 12))
    }
    public func authorizeMoneroBroadcast(_ proposal: MoneroProposal, password: String) throws {
        guard contents != nil, !proposal.isExpired else { throw WalletError.locked }
        let (disk, _, _) = try open(password: password)
        guard let record = disk.wallets.first(where: { $0.summary.id == proposal.walletID }), record.summary.canSign,
              record.summary.allAccounts.contains(where: { $0.profile?.family == .monero && $0.address == proposal.sender }) else { throw WalletError.invalid(L("message.xmr_broadcast_authorization_does_not_match_the_current_wallet")) }
    }
    public func signNative(plan: NativeTransferPlan, walletID: UUID, password: String) throws -> NativeSignedTransfer {
        guard contents != nil else { throw WalletError.locked }
        guard !plan.isExpired, let profile = AccountProfile.find(plan.profileID), profile.family == plan.family else { throw WalletError.invalid(L("message.the_multichain_transaction_expired_or_the_account_does_not_match")) }
        let (disk, _, _) = try open(password: password)
        guard let record = disk.wallets.first(where: { $0.summary.id == walletID }), record.summary.canSign,
              let account = record.summary.allAccounts.first(where: { $0.profileID == plan.profileID }), account.networkAddress == plan.sender else { throw WalletError.invalid(L("message.the_selected_wallet_does_not_control_this_transfer_account")) }
        let key = try record.summary.kind == .privateKey ? record.material : privateKey(record, account: account).hexString
        let result = try MultichainCrypto.execute(.init(action: "transferSign", profile: profile, key: key, transfer: plan.payload))
        guard result.unsigned == plan.unsigned, let signed = result.signed, let hash = result.hash, !hash.isEmpty else { throw WalletError.invalid(L("message.the_signing_data_does_not_match_the_approved_transfer_preview")) }
        return NativeSignedTransfer(hash: hash, family: plan.family, chainID: plan.chainID, encoded: signed)
    }
    public func changePassword(current: String, replacement: String) throws {
        guard contents != nil else { throw WalletError.locked }
        guard replacement.count >= 12 else { throw WalletError.invalid(L("message.the_new_password_must_contain_at_least_12_characters")) }
        let (verified, _, _) = try open(password: current)
        let newSalt = try Data.secureRandom(count: 32)
        let newKey = try derive(password: replacement, salt: newSalt)
        let oldContents = contents; let oldKey = key; let oldSalt = salt
        contents = verified; key = newKey; salt = newSalt
        do { try persist() } catch { contents = oldContents; key = oldKey; salt = oldSalt; throw error }
        sessionID = UUID()
    }
    public func rename(walletID: UUID, name: String) throws {
        guard var updated = contents else { throw WalletError.locked }
        guard let index = updated.wallets.firstIndex(where: { $0.summary.id == walletID }) else { throw WalletError.invalid(L("message.wallet_not_found")) }
        updated.wallets[index].summary.name = try validName(name)
        let original = contents; contents = updated
        do { try persist() } catch { contents = original; throw error }
    }
    public func remove(walletID: UUID, password: String) throws {
        guard contents != nil else { throw WalletError.locked }
        var (verified, _, _) = try open(password: password)
        guard verified.wallets.contains(where: { $0.summary.id == walletID }) else { throw WalletError.invalid(L("message.wallet_not_found")) }
        verified.wallets.removeAll { $0.summary.id == walletID }
        let original = contents; contents = verified
        do { try persist() } catch { contents = original; throw error }
    }
    private func privateKey(_ record: WalletSecret, account: WalletAccount) throws -> Data {
        switch record.summary.kind {
        case .mnemonic: return try MultichainCrypto.privateKey(phrase: record.material, passphrase: record.passphrase, account: account)
        case .privateKey:
            if account.profileID == "evm" { return try Data(strictHex: record.material) }
            guard let profile = account.profile, let key = try MultichainCrypto.execute(.init(action: "address", profile: profile, key: record.material)).key else { throw WalletError.invalid(L("message.private_key_parsing_failed")) }
            return try Data(strictHex: key)
        case .watch: throw WalletError.invalid(L("message.a_watch_only_wallet_cannot_sign"))
        }
    }
    private func append(_ record: WalletSecret) throws {
        guard var updated = contents else { throw WalletError.locked }
        guard !updated.wallets.contains(where: { $0.summary.kind == record.summary.kind && $0.summary.allAccounts.first?.profileID == record.summary.allAccounts.first?.profileID && $0.summary.address == record.summary.address }) else { throw WalletError.invalid(L("message.this_address_already_exists")) }
        updated.wallets.append(record)
        let original = contents; contents = updated
        do { try persist() } catch { contents = original; throw error }
    }
    private func validName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40 else { throw WalletError.invalid(L("message.wallet_names_must_contain_1_40_characters")) }; return value
    }
    private func derive(password: String, salt: Data) throws -> SymmetricKey {
        SymmetricKey(data: try KeyDerivation.pbkdf2(password: Data(password.utf8), salt: salt, rounds: Self.rounds, count: 32))
    }
    private func open(password: String) throws -> (VaultContents, Envelope, SymmetricKey) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 8 * 1024 * 1024 else { throw WalletError.vaultAuthentication }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.rounds == Self.rounds, envelope.salt.count == 32 else { throw WalletError.vaultAuthentication }
            let key = try derive(password: password, salt: envelope.salt)
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let plain = try AES.GCM.open(box, using: key, authenticating: Data("VeilWallet.vault.v1".utf8))
            return (try JSONDecoder().decode(VaultContents.self, from: plain), envelope, key)
        } catch { throw WalletError.vaultAuthentication }
    }
    private func persist() throws {
        guard let contents, let key, let salt else { throw WalletError.locked }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(contents), using: key, authenticating: Data("VeilWallet.vault.v1".utf8))
        guard let combined = sealed.combined else { throw WalletError.invalid(L("message.vault_encryption_failed")) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(Envelope(version: 1, rounds: Self.rounds, salt: salt, sealed: combined))
        // macOS can reject explicit Class-A assignment with EPERM (reproduced on this host).
        // The vault is already AES-GCM encrypted; macOS uses its filesystem's protection class.
        #if os(macOS)
        try encoded.write(to: url, options: .atomic)
        #else
        try encoded.write(to: url, options: [.atomic, .completeFileProtection])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
