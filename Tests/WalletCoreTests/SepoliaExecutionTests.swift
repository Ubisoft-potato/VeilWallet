import Foundation
import Testing
import BigInt
@testable import WalletCore

// Developer-only timing: method, public four-byte selector and completion state.
// Never write request/response bodies, addresses, signatures or credentials.
private actor SepoliaTimingTransport: PrivateRequesting {
    let base: any PrivateRequesting
    let url: URL
    init(base: any PrivateRequesting, url: URL) { self.base = base; self.url = url }
    private func record(_ values: [String: JSONValue]) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(values) + Data([10]))
    }
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
        let method = body["method"]?.string ?? "unknown"
        let id = UUID().uuidString
        var row: [String: JSONValue] = ["id": .string(id), "method": .string(method), "phase": .string("started"), "time": .number(Int(Date().timeIntervalSince1970))]
        if ["eth_call", "eth_estimateGas"].contains(method), case .array(let params) = body["params"], let data = params.first?["data"]?.string { row["selector"] = .string(String(data.prefix(10))) }
        try record(row)
        do {
            let result = try await base.execute(request)
            try record(["id": .string(id), "phase": .string("completed"), "time": .number(Int(Date().timeIntervalSince1970))])
            return result
        } catch {
            try record(["id": .string(id), "phase": .string("transport-failed"), "time": .number(Int(Date().timeIntervalSince1970))])
            throw error
        }
    }
}

@Suite(.serialized) struct SepoliaExecutionTests {
    @Test(arguments: [UInt32(100), 500, 3000, 10000])
    func replayDecoderMatchesTheActualRouter02Encoding(_ fee: UInt32) throws {
        let venue = try #require(DexCatalog.find("uniswap-v3-11155111"))
        let wrapped = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
        let outputContract = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        let recipient = "0x000000000000000000000000000000000000dEaD"
        let path = try Data(strictHex: wrapped) + Data([UInt8(fee >> 16), UInt8((fee >> 8) & 255), UInt8(fee & 255)]) + Data(strictHex: outputContract)
        let swap = try ContractInvocation(contract: venue.router, signature: "exactInput((bytes,address,uint256,uint256))", arguments: [ContractABI.json(["0x" + path.hexString, recipient, "100", "90"])])
        let refund = try ContractInvocation(contract: venue.router, signature: "refundETH()", arguments: [])
        let call = try ContractInvocation(contract: venue.router, signature: "multicall(uint256,bytes[])", arguments: ["9999999999", ContractABI.json(["0x" + swap.data.hexString, "0x" + refund.data.hexString])], nativeValue: 100)
        let decoded = try Self.router02Swap(call.data, output: outputContract)
        #expect(decoded.amount == 100 && decoded.minimum == 90 && decoded.recipient.lowercased() == recipient.lowercased() && decoded.fee == fee)
    }
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEIL_SEPOLIA_VERIFY"] == "1"))
    func publicFundingQuotesAndOptionalRealSwaps() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let funding = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent(".build/ProtocolAcceptance/funding.json")))
        let owner = try #require(funding["evm"])
        let hash = try #require(ProcessInfo.processInfo.environment["VEIL_SEPOLIA_FUNDING_HASH"])
        let chain = try #require(Chain.defaults.first { $0.id == 11155111 && $0.isTestnet })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veil-sepolia-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NetworkGate()
        let tor = TorController(gate: gate, bundle: root.appendingPathComponent("Vendor/Tor"), dataDirectory: directory.appendingPathComponent("tor"))
        defer { tor.stop() }
        tor.start()
        for _ in 0..<360 {
            if gate.isReady { break }
            if case .failed = tor.state { throw WalletError.invalid("Sepolia test Tor bootstrap failed") }
            try await Task.sleep(for: .milliseconds(500))
        }
        try #require(gate.isReady)
        let traced = SepoliaTimingTransport(base: TorTransport(gate: gate), url: root.appendingPathComponent(".build/ProtocolAcceptance/sepolia-rpc-timing.jsonl"))
        let rpc = RPCClient(transport: traced, chain: chain, isolation: "sepolia-acceptance")
        try await rpc.verifyChain()
        let tx = try await rpc.call("eth_getTransactionByHash", params: [.string(hash)])
        let receipt = try await rpc.call("eth_getTransactionReceipt", params: [.string(hash)])
        try #require(tx["hash"]?.string?.lowercased() == hash.lowercased())
        try #require(tx["to"]?.string?.lowercased() == owner.lowercased())
        try #require(receipt["transactionHash"]?.string?.lowercased() == hash.lowercased())
        try #require(receipt["status"] == .string("0x1"))
        let amount = try Ethereum.decodeQuantity(try #require(tx["value"]?.string))
        try #require(amount > 0)
        let height = try #require(receipt["blockNumber"]?.string)
        let canonical = try await rpc.call("eth_getBlockByNumber", params: [.string(height), .bool(false)])
        let head = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        try #require(canonical["hash"] == receipt["blockHash"])
        let tip = try Ethereum.decodeQuantity(try #require(head["number"]?.string))
        let block = try Ethereum.decodeQuantity(height)
        try #require(tip >= block)
        let confirmations = tip - block + 1
        try #require(confirmations >= 12)
        let balance = try await rpc.balance(address: owner)
        var report: [String: JSONValue] = ["network": .string("Ethereum Sepolia"), "chainID": .number(11155111), "fundingHash": .string(hash), "receivedWei": .string(String(amount)), "balanceWei": .string(String(balance)), "confirmations": .string(String(confirmations)), "result": .string("canonical-funding-confirmed")]
        let file = root.appendingPathComponent(".build/ProtocolAcceptance/sepolia-funding.json")
        try JSONEncoder().encode(report).write(to: file, options: .atomic)
        print("Sepolia funding confirmed: " + Ethereum.formatUnits(amount) + " test ETH, " + String(confirmations) + " confirmations")
        let token = try Token(chainID: chain.id, contract: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", symbol: "TEST USDC", decimals: 6)
        let dex = DexClient(rpc: rpc)
        if ProcessInfo.processInfo.environment["VEIL_SEPOLIA_EXECUTE"] == "1" {
            try await executeSwaps(rpc: rpc, owner: owner, token: token, root: root)
            return
        }
        var quotes: [JSONValue] = []
        for venue in DexCatalog.all.filter({ $0.chainID == chain.id }) {
            do {
                let quote = try await dex.quote(sender: owner, input: nil, output: token, amount: "0.0001", venueID: venue.id, fee: 0)
                quotes.append(.object(["venue": .string(venue.id), "amountOut": .string(String(quote.amountOut)), "fee": .number(Int(quote.fee)), "result": .string("quoted")]))
                print("Sepolia existing pool quote passed: " + venue.id)
            } catch {
                quotes.append(.object(["venue": .string(venue.id), "result": .string("quote-unavailable")]))
                print("Sepolia existing pool quote unavailable: " + venue.id)
            }
        }
        report["quotes"] = .array(quotes)
        try JSONEncoder().encode(report).write(to: file, options: .atomic)
    }

    /// Small public-testnet calls only. Every transaction must reach the normal
    /// canonical confirmation threshold before the final success report.
    private func executeSwaps(rpc: RPCClient, owner: String, token: Token, root: URL) async throws {
        try #require(rpc.chain.id == 11155111 && rpc.chain.isTestnet)
        let base = root.appendingPathComponent(".build/ProtocolAcceptance")
        let journalURL = base.appendingPathComponent("sepolia-execution-journal.json")
        // Resume only after checking the exact saved hash on the canonical chain.
        // A missing/failed receipt never permits automatic resending.
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: base.appendingPathComponent("test-wallets.json")))
        let key = try #require(credentials["evm"])
        let directory = base.appendingPathComponent("sepolia-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
        let password = try Data.secureRandom(count: 32).base64EncodedString()
        try await vault.create(password: password)
        let wallet = try await vault.addPrivateKey(name: "Sepolia acceptance only", hex: key)
        try #require(wallet.address.lowercased() == owner.lowercased())
        let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data.secureRandom(count: 32))
        let dex = DexClient(rpc: rpc)
        var activities: [Activity] = []
        var journal = (try? JSONDecoder().decode([[String: JSONValue]].self, from: Data(contentsOf: journalURL))) ?? []
        if FileManager.default.fileExists(atPath: journalURL.path) { try #require(!journal.isEmpty) }
        var maximumOutlay: BigUInt = 0
        let budget = try Ethereum.parseUnits("0.008")
        let nativeInput = try Ethereum.parseUnits("0.0001")
        func persist() throws { try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic) }
        var prior: [String: (tx: JSONValue, receipt: JSONValue, gas: BigUInt)] = [:]
        let head = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        let tip = try Ethereum.decodeQuantity(try #require(head["number"]?.string))
        for index in journal.indices {
            let hash = try #require(journal[index]["hash"]?.string)
            let venueID = try #require(journal[index]["venue"]?.string)
            let venue = try #require(DexCatalog.find(venueID))
            try #require(venue.chainID == 11155111)
            let step = try #require(journal[index]["step"]?.string)
            try #require(["native-to-token", "token-approval", "reset", "permit2", "token-to-native"].contains(step))
            let tx = try await rpc.call("eth_getTransactionByHash", params: [.string(hash)])
            let receipt = try await rpc.call("eth_getTransactionReceipt", params: [.string(hash)])
            try #require(tx["from"]?.string?.lowercased() == owner.lowercased())
            try #require(tx["hash"]?.string?.lowercased() == hash.lowercased())
            let target = step == "token-approval" || step == "reset" ? token.contract : step == "permit2" ? EVMVenueClient.permit2 : venue.router
            try #require(tx["to"]?.string?.lowercased() == target.lowercased())
            try #require(receipt["transactionHash"]?.string?.lowercased() == hash.lowercased() && receipt["status"] == .string("0x1"))
            let height = try #require(receipt["blockNumber"]?.string)
            let number = try Ethereum.decodeQuantity(height)
            try #require(tip >= number && tip - number + 1 >= 12)
            let canonical = try await rpc.call("eth_getBlockByNumber", params: [.string(height), .bool(false)])
            try #require(canonical["hash"] == receipt["blockHash"])
            let gas = try Ethereum.decodeQuantity(try #require(receipt["gasUsed"]?.string)) * Ethereum.decodeQuantity(try #require(receipt["effectiveGasPrice"]?.string))
            maximumOutlay += gas + (try Ethereum.decodeQuantity(try #require(tx["value"]?.string)))
            prior[hash] = (tx, receipt, gas)
            journal[index]["phase"] = .string("canonical-confirmed")
        }
        if !journal.isEmpty { try persist(); print("Recovered " + String(journal.count) + " canonical Sepolia transactions without resending") }
        let transferTopic = "0x" + Data("Transfer(address,address,uint256)".utf8).keccak256.hexString
        let ownerWord = try BridgeEndpoint.word(owner, networkID: 11155111).lowercased()
        func tokenTransfers(_ receipt: JSONValue, incoming: Bool) throws -> BigUInt {
            guard case .array(let logs) = receipt["logs"] else { throw WalletError.invalid("Missing public token transfer logs") }
            var amount: BigUInt = 0
            for row in logs {
                guard row["address"]?.string?.lowercased() == token.contract.lowercased(), case .array(let topics) = row["topics"], topics.count == 3,
                      topics[0].string?.lowercased() == transferTopic, topics[incoming ? 2 : 1].string?.lowercased() == ownerWord else { continue }
                let bytes = try Data(strictHex: try #require(row["data"]?.string))
                try #require(bytes.count == 32)
                amount += BigUInt(bytes)
            }
            return amount
        }
        func execute(_ preview: TransactionPreview, venue: String, step: String, fields: [String: JSONValue] = [:]) async throws -> BigUInt {
            guard preview.transaction.chainID == 11155111 else { throw WalletError.invalid("Public swap execution requires the explicit Sepolia network") }
            maximumOutlay += preview.transaction.value + preview.transaction.gasLimit * preview.transaction.maxFee
            try #require(maximumOutlay <= budget)
            try await rpc.revalidate(preview)
            let raw = try await vault.sign(transaction: preview.transaction, walletID: wallet.id, password: password)
            let hash = "0x" + raw.keccak256.hexString
            var activity = Activity(walletID: wallet.id, chainID: rpc.chain.id, hash: hash, to: preview.recipient, amount: preview.amount, symbol: preview.symbol)
            activity.transaction = .evm(preview, groupID: activity.id)
            activity.transaction?.broadcastAttempts = 1
            activity.transaction?.observation = TransactionObservation(.broadcastUnknown)
            var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, preview: preview, raw: raw)
            archive.activity = activity
            try await store.saveTransaction(archive)
            var row = fields
            row.merge(["venue": .string(venue), "step": .string(step), "hash": .string(hash), "phase": .string("broadcast-unknown")]) { _, value in value }
            journal.append(row)
            try persist()
            try #require(try await rpc.broadcast(raw) == hash)
            print("Sepolia broadcast: " + venue + " " + step + " " + hash)
            for _ in 0..<90 {
                let receipt = try await rpc.call("eth_getTransactionReceipt", params: [.string(hash)])
                if receipt != .null {
                    try #require(receipt["transactionHash"]?.string?.lowercased() == hash.lowercased())
                    try #require(receipt["status"] == .string("0x1"))
                    let height = try #require(receipt["blockNumber"]?.string)
                    let block = try await rpc.call("eth_getBlockByNumber", params: [.string(height), .bool(false)])
                    try #require(block["hash"] == receipt["blockHash"])
                    let gas = try Ethereum.decodeQuantity(try #require(receipt["gasUsed"]?.string))
                    let price = try Ethereum.decodeQuantity(try #require(receipt["effectiveGasPrice"]?.string))
                    journal[journal.count - 1]["phase"] = .string("mined-pending-confirmations")
                    try persist()
                    activities.append(activity)
                    return gas * price
                }
                try await Task.sleep(for: .seconds(3))
            }
            throw WalletError.invalid("Sepolia receipt timeout; inspect the saved hash before retrying")
        }
        var results: [[String: JSONValue]] = []
        for venue in DexCatalog.all.filter({ $0.chainID == rpc.chain.id }) {
            let received: BigUInt
            let selectedFee: UInt32
            let existingBuy = journal.first { $0["venue"] == .string(venue.id) && $0["step"] == .string("native-to-token") }
            if let existingBuy, let hash = existingBuy["hash"]?.string, let saved = prior[hash] {
                let savedValue = try #require(saved.tx["value"]?.string)
                try #require(try Ethereum.decodeQuantity(savedValue) == nativeInput)
                received = try tokenTransfers(saved.receipt, incoming: true)
                try #require(received > 0)
                let input = try Data(strictHex: try #require(saved.tx["input"]?.string))
                if venue.protocol == .v2 {
                    try #require(input.count >= 132)
                    try #require(received >= BigUInt(input[4..<36]))
                    selectedFee = 3000
                } else if venue.protocol == .v3Router02 {
                    let decoded = try Self.router02Swap(input, output: token.contract)
                    try #require(decoded.amount == nativeInput && decoded.recipient.lowercased() == owner.lowercased())
                    try #require(received >= decoded.minimum)
                    selectedFee = decoded.fee
                } else {
                    let fee = try #require(existingBuy["selectedFee"]?.string)
                    selectedFee = try #require(UInt32(fee))
                    let minimum = try #require(existingBuy["minimumOut"]?.string)
                    let minimumAmount = try #require(BigUInt(minimum))
                    try #require(received >= minimumAmount)
                }
            } else {
                let before = try await rpc.balance(address: owner, token: token)
                let buy = try await dex.quote(sender: owner, input: nil, output: token, amount: "0.0001", venueID: venue.id, fee: 0)
                _ = try await execute(dex.prepareSwap(buy, sender: owner), venue: venue.id, step: "native-to-token", fields: ["selectedFee": .string(String(buy.fee)), "minimumOut": .string(String(buy.minimumOut))])
                received = try await rpc.balance(address: owner, token: token) - before
                try #require(received >= buy.minimumOut)
                selectedFee = buy.fee
            }
            let amount = received / 2
            try #require(amount > 0)
            if let completed = journal.first(where: { $0["venue"] == .string(venue.id) && $0["step"] == .string("token-to-native") }), let hash = completed["hash"]?.string, let saved = prior[hash] {
                try #require(try tokenTransfers(saved.receipt, incoming: false) == amount)
                let input = try Data(strictHex: try #require(saved.tx["input"]?.string))
                let minimum: BigUInt
                if venue.protocol == .v2 {
                    try #require(input.count >= 164 && BigUInt(input[4..<36]) == amount)
                    minimum = BigUInt(input[36..<68])
                } else {
                    let text = try #require(completed["minimumOut"]?.string)
                    minimum = try #require(BigUInt(text))
                }
                let height = try Ethereum.decodeQuantity(try #require(saved.receipt["blockNumber"]?.string))
                try #require(height > 0)
                var nativeValidation = "historical-native-balances"
                if completed["liveBalanceChecks"] == .bool(true) {
                    let beforeText = try #require(completed["nativeBefore"]?.string)
                    let afterText = try #require(completed["nativeAfter"]?.string)
                    let before = try #require(BigUInt(beforeText)), after = try #require(BigUInt(afterText))
                    try #require(after + saved.gas >= before + minimum)
                    nativeValidation = "recorded-live-balances-and-canonical-receipt"
                } else { do {
                    let beforeValue = try await rpc.call("eth_getBalance", params: [.string(owner), .string(Ethereum.quantity(height - 1))])
                    let afterValue = try await rpc.call("eth_getBalance", params: [.string(owner), .string(Ethereum.quantity(height))])
                    let before = try Ethereum.decodeQuantity(try #require(beforeValue.string))
                    let after = try Ethereum.decodeQuantity(try #require(afterValue.string))
                    try #require(after + saved.gas >= before + minimum)
                } catch WalletError.rpcRejected(let code) where [-32000, -32001].contains(code) && venue.protocol == .v2 {
                    // Pruned providers may reject old state even though they
                    // retain receipts. Verify the exact pinned-router payout
                    // calldata and real wrapped-native withdrawal event instead.
                    try #require(input.prefix(4) == Data("swapExactTokensForETH(uint256,uint256,address[],address,uint256)".utf8).keccak256.prefix(4))
                    let ownerNumber = BigUInt(try Data(strictHex: owner))
                    try #require(input.count >= 260 && BigUInt(input[100..<132]) == ownerNumber)
                    let pathOffset = try #require(Int(exactly: BigUInt(input[68..<100])))
                    try #require(pathOffset <= input.count)
                    let start = 4 + pathOffset
                    try #require(start >= 4 && start <= input.count - 96)
                    try #require(BigUInt(input[start..<(start + 32)]) == 2)
                    let wrapped = try await EVMVenueClient(rpc: rpc).verify(venue)
                    let tokenBytes = try Data(strictHex: token.contract), wrappedBytes = try Data(strictHex: wrapped)
                    try #require(Data(input[(start + 44)..<(start + 64)]) == tokenBytes)
                    try #require(Data(input[(start + 76)..<(start + 96)]) == wrappedBytes)
                    let topic = "0x" + Data("Withdrawal(address,uint256)".utf8).keccak256.hexString
                    let routerWord = try BridgeEndpoint.word(venue.router, networkID: 11155111).lowercased()
                    guard case .array(let logs) = saved.receipt["logs"] else { throw WalletError.invalid("Missing canonical wrapped withdrawal logs") }
                    var paid: BigUInt = 0
                    for row in logs {
                        guard row["address"]?.string?.lowercased() == wrapped.lowercased(), case .array(let topics) = row["topics"], topics.count == 2,
                              topics[0].string?.lowercased() == topic, topics[1].string?.lowercased() == routerWord else { continue }
                        let data = try Data(strictHex: try #require(row["data"]?.string))
                        try #require(data.count == 32)
                        paid += BigUInt(data)
                    }
                    try #require(paid >= minimum && minimum > 0)
                    nativeValidation = "canonical-router-recipient-and-wrapped-withdrawal-event"
                } }
                results.append(["venue": .string(venue.id), "result": .string("recovered-canonical-receipts-checked"), "nativeValidation": .string(nativeValidation)])
                continue
            }
            let text = Ethereum.formatUnits(amount, decimals: token.decimals, precision: token.decimals)
            var sell = try await dex.quote(sender: owner, input: token, output: nil, amount: text, venueID: venue.id, fee: selectedFee)
            for _ in 0..<3 {
                let requirement = try await dex.approvalRequirement(sell, sender: owner)
                if requirement == .none { break }
                _ = try await execute(dex.prepareApproval(sell, sender: owner), venue: venue.id, step: requirement == .permit2 ? "permit2" : requirement == .reset ? "reset" : "token-approval")
                sell = try await dex.quote(sender: owner, input: token, output: nil, amount: text, venueID: venue.id, fee: selectedFee)
            }
            try #require(try await dex.approvalRequirement(sell, sender: owner) == .none)
            let tokenBefore = try await rpc.balance(address: owner, token: token)
            let nativeBefore = try await rpc.balance(address: owner)
            let fee = try await execute(dex.prepareSwap(sell, sender: owner), venue: venue.id, step: "token-to-native", fields: ["minimumOut": .string(String(sell.minimumOut))])
            let tokenAfter = try await rpc.balance(address: owner, token: token)
            let nativeAfter = try await rpc.balance(address: owner)
            try #require(tokenBefore - tokenAfter == amount)
            try #require(nativeAfter + fee >= nativeBefore + sell.minimumOut)
            journal[journal.count - 1]["liveBalanceChecks"] = .bool(true)
            journal[journal.count - 1]["nativeBefore"] = .string(String(nativeBefore))
            journal[journal.count - 1]["nativeAfter"] = .string(String(nativeAfter))
            try persist()
            results.append(["venue": .string(venue.id), "result": .string("balances-checked-awaiting-canonical-confirmations")])
        }
        for activity in activities {
            var confirmed = false
            for _ in 0..<120 {
                let observation = try await rpc.observe(activity: activity)
                if observation.phase == .confirmed { confirmed = true; break }
                try #require(![.failed, .conflicted, .expired].contains(observation.phase))
                try await Task.sleep(for: .seconds(3))
            }
            try #require(confirmed)
            let index = try #require(journal.firstIndex { $0["hash"] == .string(activity.hash) })
            journal[index]["phase"] = .string("canonical-confirmed")
            try persist()
        }
        for index in results.indices { results[index]["result"] = .string("public-testnet-round-trip-canonical-confirmed-and-balances-checked") }
        let report: [String: JSONValue] = ["chainID": .number(11155111), "mainnetFundsUsed": .bool(false), "venues": .array(results.map(JSONValue.object)), "transactions": .array(journal.map(JSONValue.object)), "maximumOutlayWei": .string(String(maximumOutlay))]
        try JSONEncoder().encode(report).write(to: base.appendingPathComponent("sepolia-executed.json"), options: .atomic)
        print("Sepolia public round trips passed for " + String(results.count) + " DEX deployments")
    }

    // Decode only the exact Router02 multicall/one-hop exactInput shape emitted
    // by this test; bounds and recipient/amount are checked before resuming.
    private static func router02Swap(_ input: Data, output: String) throws -> (amount: BigUInt, minimum: BigUInt, recipient: String, fee: UInt32) {
        func integer(_ data: Data, _ offset: Int) throws -> Int {
            try #require(offset >= 0 && offset <= data.count - 32)
            let value = try #require(Int(exactly: BigUInt(data[offset..<(offset + 32)])))
            try #require(value <= data.count)
            return value
        }
        try #require(input.prefix(4) == Data("multicall(uint256,bytes[])".utf8).keccak256.prefix(4))
        let start = try 4 + integer(input, 36)
        let count = try integer(input, start)
        try #require((1...3).contains(count))
        let first = try start + 32 + integer(input, start + 32)
        let size = try integer(input, first)
        try #require(size >= 164 && first + 32 + size <= input.count)
        let call = Data(input[(first + 32)..<(first + 32 + size)])
        try #require(call.prefix(4) == Data("exactInput((bytes,address,uint256,uint256))".utf8).keccak256.prefix(4))
        let tuple = try 4 + integer(call, 4)
        try #require(tuple + 128 <= call.count)
        let pathStart = try tuple + integer(call, tuple)
        let pathSize = try integer(call, pathStart)
        try #require(pathSize == 43 && pathStart + 32 + pathSize <= call.count)
        let path = Data(call[(pathStart + 32)..<(pathStart + 32 + pathSize)])
        let expectedOutput = try Data(strictHex: output)
        try #require(path.suffix(20) == expectedOutput)
        let recipient = "0x" + Data(call[(tuple + 44)..<(tuple + 64)]).hexString
        let fee = UInt32(path[20]) << 16 | UInt32(path[21]) << 8 | UInt32(path[22])
        try #require([100, 500, 3000, 10000].contains(fee))
        return (BigUInt(call[(tuple + 64)..<(tuple + 96)]), BigUInt(call[(tuple + 96)..<(tuple + 128)]), recipient, fee)
    }
}
