import Foundation
import Combine
import BigInt
import Darwin

public struct MoneroBalance: Sendable {
    public let total: BigUInt
    public let unlocked: BigUInt
    public let height: BigUInt
}
public struct MoneroProposal: Sendable {
    public let walletID: UUID
    public let sender: String
    public let recipient: String
    public let amount: BigUInt
    public let fee: BigUInt
    public let hash: String
    public let preparedAt: Date
    let metadata: String
    let session: UUID
    public var isExpired: Bool { Date().timeIntervalSince(preparedAt) > 90 }
}
public enum MoneroNode {
    public static let defaultURL = "http://cakexmrkbd7ptshw7vfzhzqgg77xgeavdrxm6zbu57lppfkj3fczbrqd.onion:18081"
    public static func validate(_ text: String) throws -> String {
        guard let url = URLComponents(string: text), url.scheme == "http", let host = url.host,
              host.hasSuffix(".onion"), host.count == 62,
              host.dropLast(6).utf8.allSatisfy({ (97...122).contains($0) || (50...55).contains($0) }),
              let port = url.port, (1...65535).contains(port), url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw WalletError.invalid(L("message.xmr_nodes_must_use_http_full_v3_address_onion_port")) }
        return "http://" + host + ":" + String(port)
    }
}

/// Monero's upstream wallet handles scanning and RingCT. Its kernel sandbox allows
/// outbound connections only to our literal-loopback Tor port, with DNS Mach IPC denied.
/// No remote wallet RPC, view-key upload, public address scanner or clearnet fallback.
@MainActor public final class MoneroRuntime: ObservableObject {
    @Published public private(set) var status = L("message.local_xmr_scanning_has_not_started")
    @Published public private(set) var balance: MoneroBalance?
    public private(set) var walletID: UUID?
    public private(set) var address: String?
    private var process: Process?
    private var rpc: MoneroLocalRPC?
    private var run = UUID()
    private var node: String?
    private var proxy: UInt16?
    private var restoreFrom: UInt64?
    private let executable: URL
    private let directory: URL
    private let gate: NetworkGate
    public init(executable: URL, directory: URL, gate: NetworkGate) { self.executable = executable; self.directory = directory; self.gate = gate }
    public static func sandboxProfile(rpcPort: UInt16, torPort: UInt16?) -> String {
        var profile = "(version 1)(allow default)(deny network*)(deny mach-lookup)"
        profile += "(allow network-bind (local ip \"localhost:\(rpcPort)\"))(allow network-inbound (local ip \"localhost:\(rpcPort)\"))"
        if let torPort { profile += "(allow network-outbound (remote ip \"localhost:\(torPort)\"))" }
        return profile
    }
    func open(walletID: UUID, address: String, spendKey: String, viewKey: String, cachePassword: String, node: String, restoreHeight: UInt64, offline: Bool = false) async throws {
        let validNode = try MoneroNode.validate(node)
        let port = try offline ? nil : gate.moneroProxyPort()
        if self.walletID == walletID, self.address == address, self.node == validNode, proxy == port, restoreFrom == restoreHeight, process?.isRunning == true, rpc != nil { return }
        stop(); let operation = run
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw WalletError.invalid(L("message.the_bundled_monero_runtime_or_system_sandbox_tool_is_missing")) }
        let folder = directory.appendingPathComponent(walletID.uuidString).appendingPathComponent(String(restoreHeight))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rpcPort = UInt16.random(in: 20000...60000)
        let password = try Data.secureRandom(count: 32).hexString
        let config = folder.appendingPathComponent("runtime.conf")
        guard !folder.path.contains("\n"), !folder.path.contains("\r") else { throw WalletError.invalid(L("message.invalid_monero_runtime_path")) }
        var lines = ["rpc-bind-ip=127.0.0.1", "rpc-bind-port=\(rpcPort)", "rpc-login=veil:\(password)", "wallet-dir=\(folder.path)", "log-file=/dev/null", "log-level=-1", "no-dns=1", "no-initial-sync=1", "untrusted-daemon=1", "daemon-address=\(validNode)", "non-interactive=1"]
        if let port { lines += ["proxy=127.0.0.1:\(port)"] } else { lines += ["offline=1"] }
        try (lines.joined(separator: "\n") + "\n").write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", Self.sandboxProfile(rpcPort: rpcPort, torPort: port), executable.path, "--config-file", config.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = folder
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        child.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.run == operation else { return }; self.rpc = nil; self.process = nil; self.balance = nil; self.status = L("message.the_local_xmr_runtime_exited_scanning_and_broadcast_are_blocked")
        } }
        try child.run(); process = child; status = L("message.starting_isolated_xmr_runtime")
        let client = MoneroLocalRPC(port: rpcPort, password: password)
        do {
            var available = false
            for _ in 0..<50 {
                guard child.isRunning, run == operation else { throw WalletError.invalid(L("message.xmr_runtime_startup_failed_or_was_cancelled")) }
                do { _ = try await client.call("get_version"); available = true; break } catch { try await Task.sleep(for: .milliseconds(200)) }
            }
            guard available else { throw WalletError.invalid(L("message.local_xmr_rpc_is_not_ready_no_external_wallet_service")) }
            _ = try await client.call("auto_refresh", params: ["enable": .bool(false)])
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("wallet.keys").path) {
                _ = try await client.call("open_wallet", params: ["filename": .string("wallet"), "password": .string(cachePassword)])
            } else {
                let result = try await client.call("generate_from_keys", params: ["filename": .string("wallet"), "address": .string(address), "spendkey": .string(spendKey), "viewkey": .string(viewKey), "password": .string(cachePassword), "language": .string("English"), "restore_height": .unsigned(restoreHeight), "autosave_current": .bool(true)])
                guard result["address"] == .string(address) else { throw WalletError.invalid(L("message.the_official_monero_runtime_generated_an_address_that_differs_from")) }
            }
            _ = try await client.call("auto_refresh", params: ["enable": .bool(false)])
            let actual = try await client.call("get_address", params: ["account_index": .number(0)])
            guard actual["address"] == .string(address), run == operation else { throw WalletError.invalid(L("message.local_xmr_wallet_address_does_not_match")) }
            self.walletID = walletID; self.address = address; self.rpc = client; self.node = validNode; self.proxy = port; self.restoreFrom = restoreHeight; status = offline ? L("message.local_xmr_offline_validation_ready") : L("message.local_xmr_wallet_opened_waiting_for_manual_sync")
        } catch { if run == operation { stop() }; throw error }
    }
    public func synchronize() async throws -> MoneroBalance {
        let (client, operation) = try connection()
        status = L("message.xmr_is_scanning_locally_initial_sync_from_the_restore_height")
        _ = try await client.call("refresh")
        guard operation == run, gate.isReady else { throw WalletError.networkBlocked }
        _ = try await client.call("store")
        let value = try await readBalance(client)
        guard operation == run else { throw WalletError.networkBlocked }; balance = value; status = L("message.local_xmr_scan_complete_height_0", value.height); return value
    }
    func prepareSigned(walletID: UUID, sender: String, recipient: String, amount: BigUInt) async throws -> MoneroProposal {
        let (client, operation) = try connection()
        guard self.walletID == walletID, address == sender, let profile = AccountProfile.find("monero.ledger"), MultichainCrypto.validateAddress(recipient, profile: profile), amount > 0, amount.bitWidth <= 64, balance != nil else { throw WalletError.invalid(L("message.xmr_account_is_unsynced_the_amount_is_invalid_or_the")) }
        let available = try await readBalance(client)
        guard gate.isReady, run == operation else { throw WalletError.networkBlocked }
        guard available.unlocked > amount else { throw WalletError.invalid(L("message.unlocked_xmr_balance_cannot_cover_the_amount_and_fee")) }
        let result = try await client.call("transfer", params: ["destinations": .array([.object(["amount": .unsigned(UInt64(amount)), "address": .string(recipient)])]), "account_index": .number(0), "subaddr_indices": .array([.number(0)]), "priority": .number(1), "unlock_time": .number(0), "do_not_relay": .bool(true), "get_tx_metadata": .bool(true), "get_tx_hex": .bool(false), "get_tx_key": .bool(false)])
        guard try integer(result["amount"]) == amount, let hash = result["tx_hash"]?.string, (try? Data(strictHex: hash).count) == 32,
              let metadata = result["tx_metadata"]?.string, !metadata.isEmpty, metadata.utf8.count <= 2_000_000 else { throw WalletError.invalid(L("message.the_monero_runtime_did_not_return_verifiable_local_transaction_material")) }
        let fee = try integer(result["fee"])
        guard fee > 0, available.unlocked >= amount + fee, operation == run else { throw WalletError.invalid(L("message.xmr_fees_or_runtime_session_changed_not_broadcast")) }
        return MoneroProposal(walletID: walletID, sender: sender, recipient: recipient, amount: amount, fee: fee, hash: hash, preparedAt: Date(), metadata: metadata, session: operation)
    }
    public func broadcast(_ proposal: MoneroProposal) async throws -> String {
        let (client, operation) = try connection()
        guard proposal.session == operation, proposal.walletID == walletID, proposal.sender == address, !proposal.isExpired else { throw WalletError.invalid(L("message.xmr_preview_expired_or_session_changed_not_broadcast")) }
        let available = try await readBalance(client)
        guard gate.isReady, run == operation else { throw WalletError.networkBlocked }
        guard available.unlocked >= proposal.amount + proposal.fee else { throw WalletError.invalid(L("message.unlocked_xmr_balance_changed_not_broadcast")) }
        let result = try await client.call("relay_tx", params: ["hex": .string(proposal.metadata)])
        guard result["tx_hash"]?.string == proposal.hash else { throw WalletError.invalid(L("message.the_returned_xmr_hash_differs_from_the_local_transaction_verify")) }
        guard operation == run else { throw WalletError.networkBlocked }; return proposal.hash
    }
    public func receipt(hash: String) async throws -> String {
        guard (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_xmr_transaction_hash")) }
        let (client, operation) = try connection()
        let result = try await client.call("get_transfer_by_txid", params: ["txid": .string(hash), "account_index": .number(0)])
        guard operation == run, let type = result["transfer"]?["type"]?.string else { throw WalletError.invalid(L("message.the_local_xmr_wallet_lacks_this_transaction_s_status_sync")) }
        if type == "failed" { return WalletLocalization.legacy("receipt.failed") }; return type == "out" ? WalletLocalization.legacy("receipt.confirmed") : WalletLocalization.legacy("receipt.pending")
    }
    public func observe(hash: String) async throws -> TransactionObservation {
        guard (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_xmr_hash")) }
        let (client, operation) = try connection()
        let result: JSONValue
        do { result = try await client.call("get_transfer_by_txid", params: ["txid": .string(hash), "account_index": .number(0)]) }
        catch WalletError.rpcRejected(-8) {
            guard operation == run else { throw WalletError.networkBlocked }
            return TransactionObservation(.notSeen, detail: L("message.the_local_wallet_has_not_found_this_hash_that_does"))
        }
        guard operation == run, let row = result["transfer"], row["txid"]?.string?.lowercased() == hash.lowercased(), let type = row["type"]?.string else { throw WalletError.invalid(L("message.the_local_xmr_scan_has_not_returned_a_matching_transaction")) }
        if type == "failed" { return TransactionObservation(.failed, detail: L("message.the_official_local_wallet_marked_this_transaction_failed_no_replacement")) }
        guard ["out", "pending", "pool"].contains(type) else { throw WalletError.invalid(L("message.this_is_not_an_outgoing_transaction_from_the_local_xmr")) }
        if type != "out" { return TransactionObservation(.pending) }
        let height = try integer(row["height"]), confirmations = try integer(row["confirmations"])
        guard height > 0, let count = UInt64(exactly: confirmations) else { throw WalletError.invalid(L("message.xmr_confirmation_count_is_invalid_or_missing")) }
        var observation = TransactionObservation(count >= 10 ? .confirmed : .confirming, detail: L("message.confirmation_follows_the_local_wallet_s_current_scan_keep_it"))
        observation.blockNumber = String(height); observation.confirmations = count; observation.requiredConfirmations = 10; observation.executionSucceeded = true
        if let fee = row["fee"] { observation.executionFee = String(try integer(fee)) }; return observation
    }
    public func relayArchive(_ archive: TransactionArchive) async throws -> String {
        try archive.validate()
        guard archive.monero != nil, archive.sender == address else { throw WalletError.invalid(L("message.xmr_archive_differs_from_the_current_local_account")) }
        let (client, operation) = try connection()
        let result = try await client.call("relay_tx", params: ["hex": .string(archive.signedPayload)])
        guard operation == run, result["tx_hash"]?.string?.lowercased() == archive.hash.lowercased() else { throw WalletError.invalid(L("message.xmr_relay_did_not_confirm_the_original_hash_sync_and")) }; return archive.hash
    }
    public func stop() {
        run = UUID(); rpc = nil; balance = nil; walletID = nil; address = nil; node = nil; proxy = nil; restoreFrom = nil
        if let child = process, child.isRunning {
            let pid = child.processIdentifier; child.terminate()
            Task { try? await Task.sleep(for: .milliseconds(500)); if child.isRunning { Darwin.kill(pid, SIGKILL) } }
        }
        process = nil; status = L("message.xmr_runtime_stopped")
    }
    private func connection() throws -> (MoneroLocalRPC, UUID) {
        guard gate.isReady, let rpc, process?.isRunning == true else { throw WalletError.networkBlocked }; return (rpc, run)
    }
    private func readBalance(_ client: MoneroLocalRPC) async throws -> MoneroBalance {
        let result = try await client.call("get_balance", params: ["account_index": .number(0), "address_indices": .array([.number(0)]), "strict": .bool(true)])
        let height = try await client.call("get_height")
        // Upstream's top-level balance covers every subaddress in account 0,
        // even when address_indices filters the detail rows. Match our spend scope.
        guard case .array(let rows) = result["per_subaddress"], rows.count == 1, rows[0]["account_index"] == .number(0), rows[0]["address_index"] == .number(0), rows[0]["address"] == address.map(JSONValue.string) else { throw WalletError.invalid(L("message.xmr_balance_does_not_belong_to_the_current_primary_address")) }
        let total = try integer(rows[0]["balance"]); let unlocked = try integer(rows[0]["unlocked_balance"])
        guard unlocked <= total else { throw WalletError.invalid(L("message.inconsistent_local_xmr_balance")) }
        return MoneroBalance(total: total, unlocked: unlocked, height: try integer(height["height"]))
    }
    private func integer(_ value: JSONValue?) throws -> BigUInt {
        if case .number(let n) = value, n >= 0 { return BigUInt(n) }; if case .unsigned(let n) = value { return BigUInt(n) }
        guard let text = value?.string, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = BigUInt(text), n.bitWidth <= 64 else { throw WalletError.invalid(L("message.local_xmr_rpc_returned_an_invalid_integer")) }; return n
    }
}
