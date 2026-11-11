import Foundation
import Testing
import BigInt
@testable import WalletCore

private struct PublicBridgePending: Codable {
    let sourceHash: String
    let record: BridgeTransferRecord
    let destinationStart: String
    let destinationBalanceBefore: BigUInt
}

@Suite(.serialized) struct BridgeTestnetExecutionTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEIL_STARGATE_TESTNET"] == "1"))
    func officialSepoliaToBSCTestnetRouteAndOptionalDelivery() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent(".build/ProtocolAcceptance")
        let funding = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: base.appendingPathComponent("funding.json")))
        let owner = try #require(funding["evm"])
        let source = try #require(BridgeCatalog.find("stargate-usdt-sepolia"))
        let destination = try #require(BridgeCatalog.find("stargate-usdt-bsc-testnet"))
        let sourceChain = try #require(Chain.defaults.first { $0.id == source.networkID && $0.isTestnet })
        let destinationChain = try #require(Chain.defaults.first { $0.id == destination.networkID && $0.isTestnet })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veil-public-bridge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NetworkGate()
        let tor = TorController(gate: gate, bundle: root.appendingPathComponent("Vendor/Tor"), dataDirectory: directory.appendingPathComponent("tor"))
        defer { tor.stop() }
        tor.start()
        for _ in 0..<360 {
            if gate.isReady { break }
            if case .failed = tor.state { throw WalletError.invalid("Testnet bridge Tor bootstrap failed") }
            try await Task.sleep(for: .milliseconds(500))
        }
        try #require(gate.isReady)
        let transport = TorTransport(gate: gate)
        let rpc = RPCClient(transport: transport, chain: sourceChain, isolation: "stargate-public-testnet")
        let remote = RPCClient(transport: transport, chain: destinationChain, isolation: "stargate-public-testnet-destination")
        let bridge = BridgeClient(transport: transport, chains: [sourceChain, destinationChain], isolation: "stargate-public-testnet")
        try await rpc.verifyChain(); try await remote.verifyChain()
        // Official pinned deployment artifacts identify these TokenMessaging
        // contracts; the actual on-chain EIDs and peers must agree in both directions.
        let messaging = "0xfB112f7FC5725de9F630abB23E4916d6fd7526d3"
        let remoteMessaging = "0xe19525580913971d220dBa3BbD01eE2A0b1adc6F"
        for (client, pool, endpointID) in [(rpc, source, source.endpointID), (remote, destination, destination.endpointID)] {
            let endpoint = try await ContractABI.address(client.readContract(ContractInvocation(contract: pool.contract, signature: "endpoint()", arguments: [])))
            try #require(try await ContractABI.uint(client.readContract(ContractInvocation(contract: endpoint, signature: "eid()", arguments: []))) == BigUInt(endpointID))
        }
        let peer = try await rpc.readContract(ContractInvocation(contract: messaging, signature: "peers(uint32)", arguments: [String(destination.endpointID)]))
        let reverse = try await remote.readContract(ContractInvocation(contract: remoteMessaging, signature: "peers(uint32)", arguments: [String(source.endpointID)]))
        let expectedPeer = try Data(strictHex: BridgeEndpoint.word(remoteMessaging, networkID: destination.networkID))
        let expectedReverse = try Data(strictHex: BridgeEndpoint.word(messaging, networkID: source.networkID))
        try #require(peer == expectedPeer)
        try #require(reverse == expectedReverse)
        var quote = try await bridge.quote(sourceID: source.id, destinationID: destination.id, sender: owner, recipient: owner, amount: "0.1")
        let preflight: [String: JSONValue] = ["source": .string(source.id), "destination": .string(destination.id), "nativeFeeWei": .string(String(quote.nativeFee)), "minimumDestination": .string(String(quote.minimumDestination)), "result": .string("official-eids-peers-and-quote-verified")]
        try JSONEncoder().encode(preflight).write(to: base.appendingPathComponent("stargate-testnet-preflight.json"), options: .atomic)
        print("Official Stargate testnet peers, EIDs and quote verified")
        guard ProcessInfo.processInfo.environment["VEIL_STARGATE_TESTNET_EXECUTE"] == "1" else { return }
        let pendingURL = base.appendingPathComponent("stargate-testnet-pending.json")
        var pending: PublicBridgePending
        if FileManager.default.fileExists(atPath: pendingURL.path) {
            pending = try JSONDecoder().decode(PublicBridgePending.self, from: Data(contentsOf: pendingURL))
            try #require(pending.record.sourceID == source.id && pending.record.destinationID == destination.id)
            try #require(pending.record.sender.lowercased() == owner.lowercased() && pending.record.recipient.lowercased() == owner.lowercased())
        } else {
            let journalURL = base.appendingPathComponent("stargate-testnet-journal.json")
            try #require(!FileManager.default.fileExists(atPath: journalURL.path))
            let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: base.appendingPathComponent("test-wallets.json")))
            let key = try #require(credentials["evm"])
            let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
            let password = try Data.secureRandom(count: 32).base64EncodedString()
            try await vault.create(password: password)
            let wallet = try await vault.addPrivateKey(name: "Public bridge acceptance only", hex: key)
            try #require(wallet.address.lowercased() == owner.lowercased())
            let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data.secureRandom(count: 32))
            var journal: [[String: JSONValue]] = []
            var maximumOutlay: BigUInt = 0
            let budget = try Ethereum.parseUnits("0.008")
            func execute(_ preview: TransactionPreview, step: String, bridgePending: PublicBridgePending? = nil) async throws -> String {
                try #require(preview.transaction.chainID == 11155111)
                maximumOutlay += preview.transaction.value + preview.transaction.gasLimit * preview.transaction.maxFee
                try #require(maximumOutlay <= budget)
                try await rpc.revalidate(preview)
                let raw = try await vault.sign(transaction: preview.transaction, walletID: wallet.id, password: password)
                let hash = "0x" + raw.keccak256.hexString
                var activity = Activity(walletID: wallet.id, chainID: source.networkID, hash: hash, to: preview.recipient, amount: preview.amount, symbol: preview.symbol)
                activity.transaction = .evm(preview, groupID: activity.id)
                if case .bridge(let quote, _) = preview.purpose { activity.bridge = quote.record }
                activity.transaction?.broadcastAttempts = 1
                activity.transaction?.observation = TransactionObservation(.broadcastUnknown)
                var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, preview: preview, raw: raw); archive.activity = activity
                try await store.saveTransaction(archive)
                journal.append(["step": .string(step), "hash": .string(hash), "phase": .string("broadcast-unknown")])
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                if let bridgePending {
                    let saved = PublicBridgePending(sourceHash: hash, record: bridgePending.record, destinationStart: bridgePending.destinationStart, destinationBalanceBefore: bridgePending.destinationBalanceBefore)
                    try JSONEncoder().encode(saved).write(to: pendingURL, options: .atomic)
                }
                try #require(try await rpc.broadcast(raw) == hash)
                print("Stargate testnet broadcast: " + step + " " + hash)
                for _ in 0..<150 {
                    let observation = try await rpc.observe(activity: activity)
                    if observation.phase == .confirmed {
                        journal[journal.count - 1]["phase"] = .string("canonical-confirmed")
                        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                        return hash
                    }
                    try #require(![.failed, .conflicted, .expired].contains(observation.phase))
                    try await Task.sleep(for: .seconds(3))
                }
                throw WalletError.invalid("Testnet source confirmation pending; resume by saved hash")
            }
            let token = try source.token
            if try await rpc.balance(address: owner, token: token) < 100_000 {
                let mint = try ContractInvocation(contract: token.contract, signature: "mint(address,uint256)", arguments: [owner, "10000000"])
                _ = try await execute(rpc.prepareContract(sender: owner, invocation: mint), step: "test-token-mint")
            }
            quote = try await bridge.quote(sourceID: source.id, destinationID: destination.id, sender: owner, recipient: owner, amount: "0.1")
            for _ in 0..<2 {
                if try await !bridge.needsApproval(quote) { break }
                guard case .evm(let approval) = try await bridge.prepareApproval(quote) else { throw WalletError.invalid("Expected Sepolia approval") }
                _ = try await execute(approval, step: "exact-approval")
                quote = try await bridge.quote(sourceID: source.id, destinationID: destination.id, sender: owner, recipient: owner, amount: "0.1")
            }
            try #require(try await !bridge.needsApproval(quote))
            guard case .evm(let preview) = try await bridge.prepareTransfer(quote) else { throw WalletError.invalid("Expected Sepolia bridge send") }
            let block = try await remote.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
            let height = try #require(block["number"]?.string)
            let before = try await remote.balance(address: owner, token: destination.token)
            let sourceBefore = try await rpc.balance(address: owner, token: token)
            let draft = PublicBridgePending(sourceHash: "", record: quote.record, destinationStart: height, destinationBalanceBefore: before)
            let hash = try await execute(preview, step: "source-send", bridgePending: draft)
            try #require(sourceBefore - (try await rpc.balance(address: owner, token: token)) == quote.amount)
            pending = PublicBridgePending(sourceHash: hash, record: quote.record, destinationStart: height, destinationBalanceBefore: before)
        }
        let requestedWait = ProcessInfo.processInfo.environment["VEIL_STARGATE_WAIT_SECONDS"] ?? "900"
        let wait = try #require(Double(requestedWait))
        try #require(wait.isFinite && (1...900).contains(wait))
        let deadline = Date().addingTimeInterval(wait)
        var observedRecord = pending.record
        while Date() < deadline {
            if observedRecord.guid == nil {
                observedRecord = try await bridge.status(record: observedRecord, sourceHash: pending.sourceHash).record
            }
            if let guid = observedRecord.guid {
                let logs = try await remote.call("eth_getLogs", params: [.object(["address": .string(destination.contract), "fromBlock": .string(pending.destinationStart), "toBlock": .string("latest"), "topics": .array([.string(BridgeClient.event("OFTReceived(bytes32,uint32,address,uint256)")), .string(guid)])])])
                if case .array(let rows) = logs, let hash = rows.first?["transactionHash"]?.string {
                    let delivered = try await bridge.status(record: observedRecord, sourceHash: pending.sourceHash, destinationHash: hash)
                    if delivered.record.destinationVerified == true {
                        let after = try await remote.balance(address: owner, token: destination.token)
                        let minimum = try #require(BigUInt(pending.record.minimumDestination))
                        try #require(after >= pending.destinationBalanceBefore + minimum)
                        let report: [String: JSONValue] = ["result": .string("public-testnet-source-and-destination-canonical-confirmed"), "sourceHash": .string(pending.sourceHash), "destinationHash": .string(hash), "guid": .string(guid), "destinationIncrease": .string(String(after - pending.destinationBalanceBefore)), "mainnetFundsUsed": .bool(false)]
                        try JSONEncoder().encode(report).write(to: base.appendingPathComponent("stargate-testnet-delivered.json"), options: .atomic)
                        print("Stargate public testnet delivery verified: " + hash)
                        return
                    }
                }
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw WalletError.invalid("Destination delivery is still unverified; saved source hash will be reused without sending again")
    }
}
