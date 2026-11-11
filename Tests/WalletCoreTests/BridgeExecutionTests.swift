import Foundation
import Testing
import BigInt
@testable import WalletCore

private struct BridgeForkTransport: PrivateRequesting {
    let ports: [String: Int]
    let tronReads: (any PrivateRequesting)?
    func execute(_ request: PrivateRequest) async throws -> Data {
        if let host = request.url.host, ["fork-1.invalid", "fork-56.invalid"].contains(host) {
            let id = host == "fork-1.invalid" ? "1" : "56"
            let transport = DevchainTransport(port: try #require(ports[id]), timeout: 120)
            return try await transport.execute(PrivateRequest(url: URL(string: "https://evm-local.invalid")!, body: request.body, isolation: request.isolation))
        }
        // Only public TRON metadata reads; no external broadcast endpoint exists.
        guard request.url.host == "api.tronstack.io", ["getblockbynum", "getcontract", "triggerconstantcontract"].contains(request.url.lastPathComponent), let tronReads else { throw WalletError.invalid("External bridge test write or unexpected endpoint rejected") }
        return try await tronReads.execute(request)
    }
}

@Suite(.serialized) struct BridgeExecutionTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEIL_BRIDGE_EXECUTION"] == "1"),
          arguments: ["stargate-usdt-eth", "stargate-usdt-bsc", "allbridge-oft-eth"].filter { sourceID in
              ProcessInfo.processInfo.environment["VEIL_BRIDGE_SOURCES"].map { sources in sources.split(separator: ",").contains(Substring(sourceID)) } ?? true
          })
    func realSourceApprovalSendAndGUIDCannotImplyDestinationDelivery(_ sourceID: String) async throws {
        let configuration = try #require(ProcessInfo.processInfo.environment["VEIL_PROTOCOL_PORTS"])
        let configURL = URL(fileURLWithPath: configuration)
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: configURL))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NetworkGate()
        let tor = TorController(gate: gate, bundle: root.appendingPathComponent("Vendor/Tor"), dataDirectory: directory.appendingPathComponent("tor"))
        defer { tor.stop() }
        if sourceID == "allbridge-oft-eth" {
            tor.start()
            for _ in 0..<360 {
                if gate.isReady { break }
                if case .failed = tor.state { throw WalletError.invalid("Bridge metadata Tor bootstrap failed") }
                try await Task.sleep(for: .milliseconds(500))
            }
            try #require(gate.isReady)
        }
        let transport = BridgeForkTransport(ports: ports, tronReads: sourceID == "allbridge-oft-eth" ? TorTransport(gate: gate) : nil)
        let chains = Chain.defaults.filter { [UInt64(1), 56, TronAddress.chainID].contains($0.id) }.map { original in
            var chain = original
            if chain.isEVM { chain.rpcURL = "https://fork-" + String(chain.id) + ".invalid" }
            return chain
        }
        let source = try #require(BridgeCatalog.find(sourceID))
        let target = try #require(BridgeCatalog.destinations(for: source).first)
        let chain = try #require(chains.first { $0.id == source.networkID })
        let control = DevchainTransport(port: try #require(ports[String(chain.id)]), timeout: 120)
        try await control.synchronizeClock()
        let rpc = RPCClient(transport: transport, chain: chain, isolation: "bridge-local-execution")
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
        let password = try Data.secureRandom(count: 32).base64EncodedString()
        try await vault.create(password: password)
        let wallet = try await vault.addPrivateKey(name: "Disposable bridge test", hex: Data.secureRandom(count: 32).hexString)
        _ = try await control.control("anvil_setBalance", params: [.string(wallet.address), .string(Ethereum.quantity(BigUInt(100) * BigUInt(10).power(18)))])
        let recipient = target.networkID == TronAddress.chainID ? "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR" : wallet.address
        let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data.secureRandom(count: 32))
        var hashes: [String] = []
        func execute(_ preview: TransactionPreview) async throws -> String {
            try await rpc.revalidate(preview)
            let raw = try await vault.sign(transaction: preview.transaction, walletID: wallet.id, password: password)
            let hash = "0x" + raw.keccak256.hexString
            var activity = Activity(walletID: wallet.id, chainID: chain.id, hash: hash, to: preview.recipient, amount: preview.amount, symbol: chain.symbol)
            activity.transaction = .evm(preview, groupID: activity.id)
            activity.transaction?.broadcastAttempts = 1
            activity.transaction?.observation = TransactionObservation(.broadcastUnknown)
            var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, preview: preview, raw: raw); archive.activity = activity
            try await store.saveTransaction(archive)
            try #require(try await rpc.broadcast(raw) == hash)
            _ = try await control.control("anvil_mine", params: [.string("0x10"), .string("0x0")])
            try #require(try await rpc.observe(activity: activity).phase == .confirmed)
            hashes.append(hash); return hash
        }
        let dex = DexClient(rpc: rpc)
        let token = try source.token
        let buy = try await dex.quote(sender: wallet.address, input: nil, output: token, amount: "0.01", venueID: "uniswap-v2-" + String(chain.id))
        _ = try await execute(dex.prepareSwap(buy, sender: wallet.address))
        let bridge = BridgeClient(transport: transport, chains: chains, isolation: "bridge-execution")
        var quote = try await bridge.quote(sourceID: source.id, destinationID: target.id, sender: wallet.address, recipient: recipient, amount: "1")
        for _ in 0..<2 {
            if try await !bridge.needsApproval(quote) { break }
            guard case .evm(let preview) = try await bridge.prepareApproval(quote) else { throw WalletError.invalid("Expected EVM source approval") }
            _ = try await execute(preview)
            quote = try await bridge.quote(sourceID: source.id, destinationID: target.id, sender: wallet.address, recipient: recipient, amount: "1")
        }
        try #require(try await !bridge.needsApproval(quote))
        let before = try await rpc.balance(address: wallet.address, token: token)
        guard case .evm(let send) = try await bridge.prepareTransfer(quote) else { throw WalletError.invalid("Expected EVM source send") }
        let hash = try await execute(send)
        let after = try await rpc.balance(address: wallet.address, token: token)
        try #require(before - after == quote.amount)
        let status = try await bridge.status(record: quote.record, sourceHash: hash)
        try #require(status.record.guid != nil)
        try #require(status.record.destinationVerified == false)
        try #require(status.label == L("message.source_confirmed_destination_receipt_unverified"))
        let report = configURL.deletingLastPathComponent().appendingPathComponent("executed-bridge-sources.json")
        var rows = (try? JSONDecoder().decode([[String: JSONValue]].self, from: Data(contentsOf: report))) ?? []
        rows.append(["source": .string(source.id), "destination": .string(target.id), "result": .string("local-source-send-confirmed-destination-unverified"), "localTransactionHashes": .array(hashes.map(JSONValue.string)), "guid": .string(status.record.guid!)])
        try JSONEncoder().encode(rows).write(to: report, options: .atomic)
    }
}
