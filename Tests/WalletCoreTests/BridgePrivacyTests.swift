import Testing
import Foundation
import BigInt
@testable import WalletCore

private let bridgeOwner = "0x000000000000000000000000000000000000dEaD"
private let bridgeTronOwner = "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR"
private func bridgeSelector(_ s: String) -> String { Data(Data(s.utf8).keccak256.prefix(4)).hexString }
private struct BridgeRPC: PrivateRequesting {
    var allowance: BigUInt = 0
    var badPeer = false
    var highFee = false
    var wrongChain = false
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
        let tron = request.url.host == "tron.test", bsc = request.url.host == "bsc.test"
        let source = BridgeCatalog.find(tron ? "allbridge-oft-tron" : "allbridge-oft-eth")!
        let target = BridgeCatalog.find(tron ? "allbridge-oft-eth" : "allbridge-oft-tron")!
        func result(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(tron ? value : .object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": value])) }
        let method = tron ? request.url.lastPathComponent : body["method"]!.string!
        if method == "getblockbynum" { return try result(.object(["blockID": .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc")])) }
        if method == "getcontract" { return try result(.object(["bytecode": .string("6000")])) }
        if method == "eth_chainId" { return try result(.string(wrongChain ? "0x2" : bsc ? "0x38" : "0x1")) }
        if method == "eth_getCode" { return try result(.string("0x6000")) }
        if method == "eth_getTransactionCount" { return try result(.string("0x0")) }
        if method == "eth_getBalance" { return try result(.string(Ethereum.quantity(BigUInt(10).power(24)))) }
        if method == "eth_estimateGas" { return try result(.string("0x30d40")) }
        if method == "eth_maxPriorityFeePerGas" || method == "eth_gasPrice" { return try result(.string("0x1")) }
        if method == "eth_getBlockByNumber" { return try result(.object(["baseFeePerGas": .string("0x1"), "timestamp": .string("0x70000000")])) }
        guard method == "eth_call" || method == "triggerconstantcontract" else { throw WalletError.invalid("Unexpected bridge mock method") }
        var params: [JSONValue] = []; if case .array(let p) = body["params"] { params = p }
        let data = tron ? body["data"]!.string! : params[0]["data"]!.string!.replacingOccurrences(of: "0x", with: "")
        let sig = String(data.prefix(8))
        let to = tron ? body["contract_address"]!.string! : params[0]["to"]!.string!
        func addressWord(_ a: String) throws -> Data { try Data(strictHex: BridgeEndpoint.word(a, networkID: tron ? TronAddress.chainID : 1)) }
        let output: Data
        switch sig {
        case bridgeSelector("decimals()"): output = ContractABI.word(bsc ? 18 : 6)
        case bridgeSelector("sharedDecimals()"): output = ContractABI.word(6)
        case bridgeSelector("chainId()"): output = ContractABI.word(BigUInt(source.protocolID))
        case bridgeSelector("getEidByChainId(uint256)"): output = ContractABI.word(BigUInt(target.endpointID))
        case bridgeSelector("oftAddress(address,uint256)"): output = try addressWord(source.contract)
        case bridgeSelector("token()"): output = try addressWord(bsc ? BridgeCatalog.find("stargate-usdt-bsc")!.tokenAddress : source.tokenAddress)
        case bridgeSelector("peers(uint32)"): output = badPeer ? ContractABI.word(1) : try Data(strictHex: BridgeEndpoint.word(target.contract, networkID: target.networkID))
        case bridgeSelector("adminFeeShareBP(address)"): output = ContractABI.word(10)
        case bridgeSelector("receiveAmount(address,uint256,uint256)"): output = ContractABI.word(9_990_000)
        case bridgeSelector("relayerFee(address,uint256,uint256)"): output = ContractABI.word(highFee ? 200 : 100)
        case bridgeSelector("allowance(address,address)"): output = ContractABI.word(allowance)
        case bridgeSelector("balanceOf(address)"): output = ContractABI.word(BigUInt(10).power(24))
        case bridgeSelector("quoteOFT(" + BridgeClient.sendTuple + ")"):
            let scale = BigUInt(10).power(bsc ? 12 : 0)
            output = [BigUInt(1), BigUInt(10).power(30), 160, 10_000_000 * scale, 9_999_999 * scale, 0].reduce(Data()) { $0 + ContractABI.word($1) }
        case bridgeSelector("quoteSend(" + BridgeClient.sendTuple + ",bool)"): output = ContractABI.word(highFee ? 200 : 100) + ContractABI.word(0)
        default:
            guard sig == bridgeSelector("approve(address,uint256)") || to.lowercased() == BridgeCatalog.find("stargate-usdt-eth")!.contract.lowercased() || sig == bridgeSelector(BridgeClient.oftBridgeSignature) else { throw WalletError.invalid("Unexpected bridge contract getter") }
            output = ContractABI.word(1)
        }
        if tron { return try result(.object(["result": .object(["result": .bool(true)]), "constant_result": .array([.string(output.hexString)]), "energy_used": .number(10)])) }
        return try result(.string("0x" + output.hexString))
    }
}
struct BridgePrivacyTests {
    private var chains: [Chain] { [Chain(id: 1, name: "ETH", symbol: "ETH", rpcURL: "https://ethereum.test"), Chain(id: 56, name: "BSC", symbol: "BNB", rpcURL: "https://bsc.test"), Chain(id: TronAddress.chainID, name: "TRON", symbol: "TRX", rpcURL: "https://tron.test", family: .tron, profiles: ["tron"], decimals: 6)] }
    private func client(_ mock: BridgeRPC = .init()) -> BridgeClient { .init(transport: mock, chains: chains, isolation: "test") }
    @Test func allbridgeQuotesBothDirectionsAndRejectsWrongPeer() async throws {
        for reverse in [false, true] {
            let a = reverse ? "allbridge-oft-tron" : "allbridge-oft-eth", b = reverse ? "allbridge-oft-eth" : "allbridge-oft-tron"
            let q = try await client().quote(sourceID: a, destinationID: b, sender: reverse ? bridgeTronOwner : bridgeOwner, recipient: reverse ? bridgeOwner : bridgeTronOwner, amount: "10")
            #expect(q.expectedDestination == 9_990_000); #expect(q.minimumLD == 9_940_050); #expect(q.nativeFee == 100)
            #expect(try await client().needsApproval(q))
            let args = try BridgeClient.arguments(q); #expect(args.arguments[1] == "10000000"); #expect(args.arguments[3] == (reverse ? "1" : "3"))
            do { _ = try await client(.init(badPeer: true)).quote(sourceID: a, destinationID: b, sender: q.sender, recipient: q.recipient, amount: "10"); Issue.record("Unrelated OFT peer accepted") } catch {}
        }
        do { _ = try await client().quote(sourceID: "allbridge-oft-tron", destinationID: "stargate-usdt-bsc", sender: bridgeTronOwner, recipient: bridgeOwner, amount: "10"); Issue.record("Unsupported direct route accepted") } catch {}
    }
    @Test func stargateSharedPrecisionAndExactApprovals() async throws {
        for reverse in [false, true] {
            let a = reverse ? "stargate-usdt-bsc" : "stargate-usdt-eth", b = reverse ? "stargate-usdt-eth" : "stargate-usdt-bsc"
            let q = try await client().quote(sourceID: a, destinationID: b, sender: bridgeOwner, recipient: bridgeOwner, amount: "10")
            let minimum = q.minimumDestination
            #expect(minimum == (reverse ? BigUInt(9_949_999) : BigUInt(9_949_999) * BigUInt(10).power(12)))
            #expect(q.absoluteMinimumEnforced)
        }
        for current: BigUInt in [0, 1] {
            let c = client(.init(allowance: current))
            let q = try await c.quote(sourceID: "allbridge-oft-eth", destinationID: "allbridge-oft-tron", sender: bridgeOwner, recipient: bridgeTronOwner, amount: "10")
            guard case .evm(let p) = try await c.prepareApproval(q) else { Issue.record("Wrong plan family"); return }
            #expect(p.purpose.invocation?.arguments == [Ethereum.checksumAddress(q.source.contract), current == 0 ? "10000000" : "0"])
        }
    }
    @Test func bridgeFinalRevalidationRejectsFeeIncreaseAndChainMismatch() async throws {
        let c = client(.init(allowance: 100_000_000))
        let q = try await c.quote(sourceID: "allbridge-oft-eth", destinationID: "allbridge-oft-tron", sender: bridgeOwner, recipient: bridgeTronOwner, amount: "10")
        let good = BridgeEndpoint.evm(RPCClient(transport: BridgeRPC(allowance: 100_000_000), chain: chains[0], isolation: "test"))
        try await BridgeClient.revalidate(q, sender: bridgeOwner, endpoint: good)
        for mock in [BridgeRPC(allowance: 100_000_000, highFee: true), BridgeRPC(allowance: 100_000_000, wrongChain: true), BridgeRPC(allowance: 0)] {
            do { try await BridgeClient.revalidate(q, sender: bridgeOwner, endpoint: .evm(RPCClient(transport: mock, chain: chains[0], isolation: "test"))); Issue.record("Changed bridge state accepted") } catch {}
        }
    }
    @Test func privacyEventSyncRejectsMissingOrForgedLeaves() throws {
        let pool = PrivacyPoolCatalog.pools[0]
        func event(_ index: Int, address: String? = nil) -> JSONValue { .object(["address": .string(address ?? pool.contract), "removed": .bool(false), "topics": .array([.string(PrivacyPoolClient.depositTopic), .string("0x" + ContractABI.word(BigUInt(index + 1)).hexString)]), "data": .string("0x" + (ContractABI.word(BigUInt(index)) + ContractABI.word(1234)).hexString), "blockNumber": .string("0xa"), "blockHash": .string("0x" + String(repeating: "01", count: 32))]) }
        let leaves = try PrivacyPoolClient.depositLeaves(.array([event(1), event(0)]), pool: pool, from: 10, to: 10, startIndex: 0)
        #expect(leaves.count == 2)
        for logs in [[event(1)], [event(0), event(0)], [event(0, address: bridgeOwner)]] {
            do { _ = try PrivacyPoolClient.depositLeaves(.array(logs), pool: pool, from: 10, to: 10, startIndex: 0); Issue.record("Incomplete/foreign deposit tree accepted") } catch {}
        }
    }
    @Test func canonicalNotesAndBoundedFixedArrays() throws {
        let note = try PrivacyNoteMaterial("tornado-eth-0.1-1-0x" + String(repeating: "00", count: 62))
        #expect(note.pool.id == "tornado-eth-0.1")
        for value in ["tornado-trx-0.1-195-0x" + String(repeating: "00", count: 62), "tornado-eth-0.1-56-0x" + String(repeating: "00", count: 62)] { do { _ = try PrivacyNoteMaterial(value); Issue.record("Mismatched note accepted") } catch {} }
        for signature in ["f(uint256[0])", "f(uint256[65])", "f(uint256[06])"] { do { _ = try ContractABI.types(signature); Issue.record("Noncanonical array accepted") } catch {} }
        do { _ = try ContractABI.encode(signature: "f(uint256[2])", arguments: ["[\"1\"]"]); Issue.record("Wrong fixed count accepted") } catch {}
    }
    @Test func bridgeDeliveryRequiresMatchingGuidRecipientAndAmount() async throws {
        let source = BridgeCatalog.find("stargate-usdt-eth")!, destination = BridgeCatalog.find("stargate-usdt-bsc")!
        let record = BridgeTransferRecord(sourceID: source.id, destinationID: destination.id, sender: bridgeOwner, recipient: bridgeOwner, sourceOFT: source.contract, destinationOFT: destination.contract, amount: "10000000", minimumDestination: "9900000000000000000")
        let sourceHash = "0x" + String(repeating: "01", count: 32), destinationHash = "0x" + String(repeating: "02", count: 32)
        let good = BridgeClient(transport: BridgeReceiptRPC(), chains: chains, isolation: "test")
        let pending = try await good.status(record: record, sourceHash: sourceHash)
        #expect(pending.label == L("message.source_confirmed_destination_receipt_unverified")); #expect(pending.record.destinationVerified != true)
        let delivered = try await good.status(record: record, sourceHash: sourceHash, destinationHash: destinationHash)
        #expect(delivered.record.destinationVerified == true)
        for problem in ["guid", "recipient", "amount"] {
            do { _ = try await BridgeClient(transport: BridgeReceiptRPC(problem: problem), chains: chains, isolation: "test").status(record: record, sourceHash: sourceHash, destinationHash: destinationHash); Issue.record("Unrelated destination delivery accepted") } catch {}
        }
    }
    @Test func privacyDepositAndWithdrawalFailClosedOnChangedPoolState() async throws {
        let pool = PrivacyPoolCatalog.pools[0], chain = chains[0]
        let note = PrivacyNoteSummary(id: UUID(), walletID: nil, poolID: pool.id, commitment: "0x" + ContractABI.word(1).hexString, createdAt: Date())
        let client = PrivacyPoolClient(rpc: RPCClient(transport: PoolRPC(), chain: chain, isolation: "test"))
        let deposit = try await client.prepareDeposit(note: note, sender: bridgeOwner)
        #expect(deposit.transaction.value == (try pool.amount)); #expect(deposit.purpose.invocation?.signature == "deposit(bytes32)")
        let proof = PrivacyProof(commitment: note.commitment, nullifierHash: "0x" + ContractABI.word(2).hexString, root: "0x" + ContractABI.word(3).hexString, proof: "0x" + String(repeating: "01", count: 256), publicSignals: ["3", "2", "57005", "0", "0", "0"])
        let withdrawal = try await client.prepareWithdrawal(note: note, proof: proof, sender: bridgeOwner)
        #expect(withdrawal.transaction.value == 0); #expect(withdrawal.purpose.invocation?.arguments[3] == bridgeOwner)
        for problem in ["spent", "root", "verifier", "denomination"] {
            let changed = RPCClient(transport: PoolRPC(problem: problem), chain: chain, isolation: "test")
            do { try await changed.revalidate(withdrawal); Issue.record("Changed privacy pool state accepted") } catch {}
        }
    }
}

private struct PoolRPC: PrivateRequesting {
    var problem = ""
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!), method = body["method"]!.string!
        guard case .array(let params) = body["params"] else { throw WalletError.invalid("Mock params") }
        let result: JSONValue
        switch method {
        case "eth_chainId": result = .string("0x1")
        case "eth_getCode": result = .string("0x6000")
        case "eth_getBalance": result = .string(Ethereum.quantity(BigUInt(10).power(24)))
        case "eth_getTransactionCount": result = .string("0x0")
        case "eth_estimateGas": result = .string("0x80000")
        case "eth_maxPriorityFeePerGas": result = .string("0x1")
        case "eth_getBlockByNumber": result = .object(["baseFeePerGas": .string("0x1")])
        case "eth_call":
            let selector = String(params[0]["data"]!.string!.dropFirst(2).prefix(8))
            let n: BigUInt
            switch selector {
            case bridgeSelector("denomination()"): n = problem == "denomination" ? 1 : try PrivacyPoolCatalog.pools[0].amount
            case bridgeSelector("levels()"): n = 20
            case bridgeSelector("verifier()"): n = 123
            case bridgeSelector("commitments(bytes32)"): n = 0
            case bridgeSelector("isKnownRoot(bytes32)"): n = problem == "root" ? 0 : 1
            case bridgeSelector("isSpent(bytes32)"): n = problem == "spent" ? 1 : 0
            case bridgeSelector("verifyProof(bytes,uint256[6])"): n = problem == "verifier" ? 0 : 1
            default: n = 1
            }
            result = .string("0x" + ContractABI.word(n).hexString)
        default: throw WalletError.invalid("Unexpected privacy RPC")
        }
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result]))
    }
}
private struct BridgeReceiptRPC: PrivateRequesting {
    var problem = ""
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!), method = body["method"]!.string!, bsc = request.url.host == "bsc.test"
        guard case .array(let params) = body["params"] else { throw WalletError.invalid("Mock params") }
        let result: JSONValue, hash = "0x" + String(repeating: "03", count: 32)
        if method == "eth_chainId" { result = .string(bsc ? "0x38" : "0x1") }
        else if method == "eth_getBlockByNumber" { result = .object(["number": .string(params[0] == .string("latest") ? "0x64" : "0x1"), "hash": .string(hash)]) }
        else if method == "eth_getTransactionReceipt" {
            let guid = "0x" + String(repeating: bsc && problem == "guid" ? "05" : "04", count: 32)
            let owner = bsc && problem == "recipient" ? "0x1111111111111111111111111111111111111111" : bridgeOwner
            let topic = BridgeClient.event(bsc ? "OFTReceived(bytes32,uint32,address,uint256)" : "OFTSent(bytes32,uint32,address,uint256,uint256)")
            let pool = BridgeCatalog.find(bsc ? "stargate-usdt-bsc" : "stargate-usdt-eth")!
            let data = bsc ? ContractABI.word(30101) + ContractABI.word(problem == "amount" ? 1 : BigUInt(10).power(19)) : ContractABI.word(30102) + ContractABI.word(10_000_000) + ContractABI.word(10_000_000)
            let log: JSONValue = .object(["address": .string(pool.contract), "topics": .array([.string(topic), .string(guid), .string(try BridgeEndpoint.word(owner, networkID: pool.networkID))]), "data": .string("0x" + data.hexString)])
            result = .object(["transactionHash": params[0], "status": .string("0x1"), "blockNumber": .string("0x1"), "blockHash": .string(hash), "logs": .array([log])])
        } else { throw WalletError.invalid("Unexpected receipt RPC") }
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result]))
    }
}
