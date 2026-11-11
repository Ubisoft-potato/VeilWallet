import Foundation
import Testing
import BigInt
@testable import WalletCore

@Suite(.serialized) struct NileExecutionTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEIL_NILE_EXECUTION"] == "1"))
    func sunswapRoundTripHasSolidifiedReceiptsAndBalanceChanges() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent(".build/ProtocolAcceptance/test-wallets.json")))
        let key = try #require(credentials["tron"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veil-nile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NetworkGate()
        let tor = TorController(gate: gate, bundle: root.appendingPathComponent("Vendor/Tor"), dataDirectory: directory.appendingPathComponent("tor"))
        defer { tor.stop() }
        tor.start()
        for _ in 0..<360 {
            if gate.isReady { break }
            if case .failed = tor.state { throw WalletError.invalid("Nile test Tor bootstrap failed") }
            try await Task.sleep(for: .milliseconds(500))
        }
        try #require(gate.isReady)
        let transport = TorTransport(gate: gate)
        let chain = TronNetwork.nile
        let client = TronContractClient(transport: transport, chain: chain, isolation: "nile-execution")
        let native = NativeTransferClient(transport: transport, chain: chain, isolation: "nile-execution")
        let dex = TronDexClient(client: client)
        let token = try Token(chainID: chain.id, contract: "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf", symbol: "TEST USDT", decimals: 6)
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
        let password = try Data.secureRandom(count: 32).base64EncodedString()
        try await vault.create(password: password)
        let wallet = try await vault.addPrivateKey(name: "Nile acceptance only", material: key, profileID: "tron")
        let account = try #require(wallet.allAccounts.first { $0.profileID == "tron" })
        let sender = account.networkAddress
        let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data.secureRandom(count: 32))
        var hashes: [String] = []

        func execute(_ plan: NativeTransferPlan) async throws -> Activity {
            try await native.revalidate(plan, account: account)
            let signed = try await vault.signNative(plan: plan, walletID: wallet.id, password: password)
            var activity = Activity(walletID: wallet.id, chainID: chain.id, hash: signed.hash, to: plan.recipient, amount: String(plan.amount), symbol: "TRX")
            activity.transaction = .native(plan, groupID: activity.id)
            activity.transaction?.broadcastAttempts = 1
            activity.transaction?.observation = TransactionObservation(.broadcastUnknown)
            var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, plan: plan, signed: signed)
            archive.activity = activity
            try await store.saveTransaction(archive)
            try #require(try await native.broadcast(signed) == signed.hash)
            hashes.append(signed.hash)
            for _ in 0..<90 {
                let result = try await native.observe(activity: activity, archive: archive)
                if result.phase == .confirmed {
                    try #require(result.executionSucceeded == true)
                    activity.transaction?.observation = result
                    return activity
                }
                try #require(![.failed, .expired, .conflicted].contains(result.phase))
                try await Task.sleep(for: .seconds(3))
            }
            throw WalletError.invalid("Nile receipt did not solidify within the test deadline")
        }

        try await client.verifyChain()
        let initial = try await client.balance(address: sender, token: token)
        let buy = try await dex.quote(sender: sender, input: nil, output: token, amount: "1", mode: .v2)
        _ = try await execute(dex.prepareSwap(buy, sender: sender))
        let received = try await client.balance(address: sender, token: token) - initial
        try #require(received >= buy.minimumOut)
        let amount = received / 2
        try #require(amount > 1)
        let amountText = Ethereum.formatUnits(amount, decimals: token.decimals, precision: token.decimals)
        var sell = try await dex.quote(sender: sender, input: token, output: nil, amount: amountText, mode: .v2)
        if try await dex.needsApproval(sell, sender: sender) {
            let approval = try await execute(dex.prepareApproval(sell, sender: sender))
            try #require(DexApprovalProgress.resolveTron(hash: approval.hash, activities: [approval], walletID: wallet.id, sender: sender, chainID: chain.id) == .ready)
            sell = try await dex.quote(sender: sender, input: token, output: nil, amount: amountText, mode: .v2)
        }
        try #require(try await !dex.needsApproval(sell, sender: sender))
        let before = try await client.balance(address: sender, token: token)
        _ = try await execute(dex.prepareSwap(sell, sender: sender))
        try #require(before - (try await client.balance(address: sender, token: token)) == amount)
        let report: [String: Any] = ["network": "TRON Nile", "result": "native-to-token-approve-token-to-native-solidified", "transactionHashes": hashes, "mainnetFundsUsed": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(".build/ProtocolAcceptance/nile-executed.json"), options: .atomic)
    }
}
