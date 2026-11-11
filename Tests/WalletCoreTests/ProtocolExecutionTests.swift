import Foundation
import Testing
import BigInt
@testable import WalletCore

/// Funded execution against real protocol contracts on isolated Anvil forks.
/// The fork runner rejects all public RPC writes before they reach Tor.
@Suite(.serialized) struct ProtocolExecutionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEIL_PROTOCOL_PORTS"] != nil),
          arguments: DexCatalog.all.filter { venue in
              [1, 56].contains(venue.chainID) && (ProcessInfo.processInfo.environment["VEIL_PROTOCOL_VENUES"].map { $0.split(separator: ",").contains(Substring(venue.id)) } ?? true)
          }.map(\.id))
    func realSwapExecutesAfterApprovalAndChangesBalances(_ venueID: String) async throws {
        guard let configuration = ProcessInfo.processInfo.environment["VEIL_PROTOCOL_PORTS"] else { return }
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: URL(fileURLWithPath: configuration)))
        let venue = try #require(DexCatalog.find(venueID))
        let port = try #require(ports[String(venue.chainID)])
        try #require((1...65535).contains(port))
        let transport = DevchainTransport(port: port, timeout: 120)
        try await transport.synchronizeClock()
        var chain = try #require(Chain.defaults.first { $0.id == venue.chainID })
        chain.rpcURL = "https://evm-local.invalid"
        let rpc = RPCClient(transport: transport, chain: chain, isolation: "execution-fixture")
        let dex = DexClient(rpc: rpc)
        let key = try Data.secureRandom(count: 32)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
        let password = try Data.secureRandom(count: 32).base64EncodedString()
        try await vault.create(password: password)
        let wallet = try await vault.addPrivateKey(name: "Disposable execution fixture", hex: key.hexString)
        let owner = wallet.address
        let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data.secureRandom(count: 32))
        _ = try await transport.control("anvil_setBalance", params: [.string(owner), .string(Ethereum.quantity(BigUInt(1000) * BigUInt(10).power(18)))])
        var hashes: [String] = []

        func execute(_ preview: TransactionPreview) async throws {
            try await rpc.revalidate(preview)
            let raw = try await vault.sign(transaction: preview.transaction, walletID: wallet.id, password: password)
            var activity = Activity(walletID: wallet.id, chainID: chain.id, hash: "0x" + raw.keccak256.hexString, to: preview.recipient, amount: preview.amount, symbol: preview.symbol)
            activity.transaction = .evm(preview, groupID: activity.id)
            activity.transaction?.broadcastAttempts = 1
            activity.transaction?.observation = TransactionObservation(.broadcastUnknown)
            var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, preview: preview, raw: raw)
            archive.activity = activity
            try await store.saveTransaction(archive)
            let sent = try await rpc.broadcast(raw)
            try #require(sent.lowercased() == activity.hash.lowercased())
            _ = try await transport.control("anvil_mine", params: [.string("0x10"), .string("0x0")])
            let observation = try await rpc.observe(activity: activity)
            let attempts = URL(fileURLWithPath: configuration).deletingLastPathComponent().appendingPathComponent("attempts-" + venueID + ".jsonl")
            let line = try JSONEncoder().encode(["hash": sent, "phase": observation.phase.rawValue, "selector": "0x" + preview.transaction.data.prefix(4).hexString]) + Data([10])
            if !FileManager.default.fileExists(atPath: attempts.path) { FileManager.default.createFile(atPath: attempts.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: attempts); try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
            try #require(observation.phase == .confirmed)
            hashes.append(sent)
        }

        let contract: String
        let decimals: Int
        if venue.protocol == .curveETH {
            contract = "0xae7ab96520de3a18e5e111b5eaab095312d7fe84"; decimals = 18
        } else if venue.protocol == .balancerV3 {
            contract = "0x6c0aeceedc55c9d55d8b99216a670d85330941c3"; decimals = 18
        } else if chain.id == 56 {
            contract = "0x55d398326f99059ff775485246999027b3197955"; decimals = 18
        } else {
            contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"; decimals = 6
        }
        let token = try Token(chainID: chain.id, contract: contract, symbol: "FIXTURE", decimals: decimals)
        let pool = venue.protocol == .balancerV3 ? "0x1846c6cbe0d433e152fa358e5ff27968e18bce7c" : nil
        let fee: UInt32 = venue.protocol == .uniswapV4 ? 3000 : venue.usesFee ? 0 : 3000
        // Curve 3pool uses ERC20 inputs, so acquire USDC through the real V2 router.
        let entryVenue = venue.protocol == .curve ? "uniswap-v2-1" : venueID
        let initial = try await rpc.balance(address: owner, token: token)
        print("Execution stage: " + venueID + " bootstrap quote")
        let quote = try await dex.quote(sender: owner, input: nil, output: token, amount: "0.001", venueID: entryVenue, fee: fee, poolID: pool)
        print("Execution stage: " + venueID + " bootstrap send")
        try await execute(dex.prepareSwap(quote, sender: owner))
        let received = try await rpc.balance(address: owner, token: token) - initial
        try #require(received >= quote.minimumOut)

        let amount = received / 2
        try #require(amount > 1)
        let output = venue.protocol == .curve ? try Token(chainID: 1, contract: "0xdac17f958d2ee523a2206206994597c13d831ec7", symbol: "FIXTURE", decimals: 6) : nil
        let amountText = Ethereum.formatUnits(amount, decimals: token.decimals, precision: token.decimals)
        // Exercise the nonzero-allowance reset, exact approval, and Permit2 stages.
        let spender = venue.usesPermit2 ? EVMVenueClient.permit2 : venue.router
        let partial = try ContractInvocation(contract: token.contract, signature: "approve(address,uint256)", arguments: [spender, "1"])
        try await execute(rpc.prepareContract(sender: owner, invocation: partial))
        var current = try await dex.quote(sender: owner, input: token, output: output, amount: amountText, venueID: venueID, fee: fee, poolID: pool)
        try #require(try await dex.approvalRequirement(current, sender: owner) == .reset)
        for _ in 0..<3 {
            if try await dex.approvalRequirement(current, sender: owner) == .none { break }
            try await execute(dex.prepareApproval(current, sender: owner))
            current = try await dex.quote(sender: owner, input: token, output: output, amount: amountText, venueID: venueID, fee: fee, poolID: pool)
        }
        try #require(try await dex.approvalRequirement(current, sender: owner) == .none)
        let inputBefore = try await rpc.balance(address: owner, token: token)
        let outputBefore = try await rpc.balance(address: owner, token: output)
        let preview = try await dex.prepareSwap(current, sender: owner)
        try await execute(preview)
        let inputAfter = try await rpc.balance(address: owner, token: token)
        let outputAfter = try await rpc.balance(address: owner, token: output)
        // stETH transfers convert pooled ETH to integer shares and back.
        // One wei may remain after that round-trip; ordinary ERC20s stay exact.
        let spent = inputBefore - inputAfter
        if venue.protocol == .curveETH { try #require(spent <= amount && amount - spent <= 2) }
        else { try #require(spent == amount) }
        let receipt = try await rpc.call("eth_getTransactionReceipt", params: [.string(hashes.last!)])
        let gas = try Ethereum.decodeQuantity(try #require(receipt["gasUsed"]?.string))
        let gasPrice = try Ethereum.decodeQuantity(try #require(receipt["effectiveGasPrice"]?.string))
        try #require(outputAfter + (output == nil ? gas * gasPrice : 0) >= outputBefore + current.minimumOut)
        try Self.record(venueID: venueID, hashes: hashes, configuration: configuration)
    }

    private static func record(venueID: String, hashes: [String], configuration: String) throws {
        let report = URL(fileURLWithPath: configuration).deletingLastPathComponent().appendingPathComponent("executed-swaps.json")
        var rows = (try? JSONDecoder().decode([[String: JSONValue]].self, from: Data(contentsOf: report))) ?? []
        rows.append(["venue": .string(venueID), "result": .string("mined-reset-approve-swap-and-balance-checks"), "localTransactionHashes": .array(hashes.map(JSONValue.string))])
        try JSONEncoder().encode(rows).write(to: report, options: .atomic)
    }
}
