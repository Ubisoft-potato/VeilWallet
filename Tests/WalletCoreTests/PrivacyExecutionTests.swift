import Foundation
import Testing
import BigInt
@testable import WalletCore

/// Genuine verifier/proof execution with freshly initialized LOCAL pool state.
/// It does not claim coverage of public relayers or existing mainnet histories.
@Suite(.serialized) struct PrivacyExecutionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEIL_PRIVACY_EXECUTION"] == "1"),
          arguments: PrivacyPoolCatalog.pools.filter { pool in
              ProcessInfo.processInfo.environment["VEIL_PRIVACY_CHAIN"].map { String(pool.chainID) == $0 } ?? true
          }.map(\.id))
    func realDepositProofWithdrawalAndDoubleSpendRejection(_ poolID: String) async throws {
        let configuration = try #require(ProcessInfo.processInfo.environment["VEIL_PROTOCOL_PORTS"])
        let configURL = URL(fileURLWithPath: configuration)
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: configURL))
        let anchors = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configURL.deletingLastPathComponent().appendingPathComponent("privacy-anchors.json")))
        let pool = try #require(PrivacyPoolCatalog.find(poolID))
        let transport = DevchainTransport(port: try #require(ports[String(pool.chainID)]), timeout: 120)
        try await transport.synchronizeClock()
        var chain = try #require(Chain.defaults.first { $0.id == pool.chainID })
        chain.rpcURL = "https://evm-local.invalid"
        let rpc = RPCClient(transport: transport, chain: chain, isolation: "privacy-local-execution")
        let client = PrivacyPoolClient(rpc: rpc)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = PrivacyProofRuntime(directory: root.appendingPathComponent("Vendor/PrivacyRuntime"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
        let password = try Data.secureRandom(count: 32).base64EncodedString()
        try await vault.create(password: password)
        let depositor = try await vault.addPrivateKey(name: "Disposable depositor", hex: Data.secureRandom(count: 32).hexString)
        let recipient = try await vault.addPrivateKey(name: "Separate gas payer", hex: Data.secureRandom(count: 32).hexString)
        for wallet in [depositor, recipient] {
            _ = try await transport.control("anvil_setBalance", params: [.string(wallet.address), .string(Ethereum.quantity(BigUInt(1000) * BigUInt(10).power(18)))])
        }
        let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data.secureRandom(count: 32))
        var hashes: [String] = []
        func execute(_ preview: TransactionPreview, wallet: WalletSummary) async throws -> BigUInt {
            try await rpc.revalidate(preview)
            guard case .privacy(let intent, _) = preview.purpose else { throw WalletError.invalid("Missing privacy intent") }
            try await vault.authorizePrivacy(intent, password: password)
            let raw = try await vault.sign(transaction: preview.transaction, walletID: wallet.id, password: password)
            let hash = "0x" + raw.keccak256.hexString
            var activity = Activity(walletID: wallet.id, chainID: chain.id, hash: hash, to: preview.recipient, amount: preview.amount, symbol: chain.symbol)
            activity.transaction = .evm(preview, groupID: activity.id)
            activity.transaction?.broadcastAttempts = 1
            activity.transaction?.observation = TransactionObservation(.broadcastUnknown)
            var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, preview: preview, raw: raw)
            archive.activity = activity
            try await store.saveTransaction(archive)
            try await vault.recordPrivacyTransaction(intent, hash: hash, password: password)
            try #require(try await rpc.broadcast(raw) == hash)
            _ = try await transport.control("anvil_mine", params: [.string("0x10"), .string("0x0")])
            try #require(try await rpc.observe(activity: activity).phase == .confirmed)
            hashes.append(hash)
            let receipt = try await rpc.call("eth_getTransactionReceipt", params: [.string(hash)])
            return try Ethereum.decodeQuantity(try #require(receipt["gasUsed"]?.string)) * Ethereum.decodeQuantity(try #require(receipt["effectiveGasPrice"]?.string))
        }
        try await client.verifyPublicProver(pool: pool, runtime: runtime)
        let note = try await vault.createPrivacyNote(poolID: pool.id, walletID: depositor.id, password: password, runtime: runtime)
        let balanceBefore = try await rpc.balance(address: pool.contract)
        _ = try await execute(client.prepareDeposit(note: note, sender: depositor.address), wallet: depositor)
        try #require(try await rpc.balance(address: pool.contract) == balanceBefore + pool.amount)
        var snapshot = PrivacyTreeSnapshot(pool: pool)
        let anchor = try #require(anchors[String(pool.chainID)])
        let anchorNumber = try Ethereum.decodeQuantity(anchor)
        snapshot.scannedBlock = try #require(UInt64(exactly: anchorNumber))
        let synced = try await client.synchronize(pool: pool, snapshot: snapshot) { _ in }
        try #require(synced.complete && synced.snapshot.leaves == [note.commitment.lowercased()])
        let material = try await PrivacyNoteMaterial(vault.privacyNote(id: note.id, password: password))
        let proof = try await runtime.prove(note: material, leaves: synced.snapshot.leaves, recipient: recipient.address, relayer: PrivacyPoolClient.zero, fee: "0")
        let deposited = try #require(try await vault.privacyNotes().first { $0.id == note.id })
        let before = try await rpc.balance(address: recipient.address)
        let fee = try await execute(client.prepareWithdrawal(note: deposited, proof: proof, sender: recipient.address), wallet: recipient)
        try #require(try await rpc.balance(address: recipient.address) + fee == before + pool.amount)
        try #require(try await rpc.balance(address: pool.contract) == balanceBefore)
        try #require(try await client.boolean(pool.contract, "isSpent(bytes32)", [proof.nullifierHash]))
        try await #require(throws: WalletError.self) { try await client.prepareWithdrawal(note: deposited, proof: proof, sender: recipient.address) }
        let report = configURL.deletingLastPathComponent().appendingPathComponent("executed-privacy.json")
        var rows = (try? JSONDecoder().decode([[String: JSONValue]].self, from: Data(contentsOf: report))) ?? []
        rows.append(["pool": .string(pool.id), "result": .string("local-real-verifier-deposit-scan-proof-withdraw-replay-rejected"), "localTransactionHashes": .array(hashes.map(JSONValue.string))])
        try JSONEncoder().encode(rows).write(to: report, options: .atomic)
    }
}
