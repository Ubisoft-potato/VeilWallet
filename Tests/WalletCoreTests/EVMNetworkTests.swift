import Foundation
import Testing
import BigInt
@testable import WalletCore

private struct FeeRPC: PrivateRequesting {
    let handler: @Sendable (String, [JSONValue]) throws -> JSONValue
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
        guard let method = body["method"]?.string, case .array(let params) = body["params"] else { throw WalletError.invalid("test request") }
        var response: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": body["id"]!]
        do { response["result"] = try handler(method, params) }
        catch WalletError.rpcRejected(let code) { response["error"] = .object(["code": .number(code), "message": .string("deliberately omitted by client")]) }
        return try JSONEncoder().encode(JSONValue.object(response))
    }
}
private let publicAddress = "0x000000000000000000000000000000000000dEaD"
private func abi(_ n: BigUInt) -> JSONValue { .string("0x" + EVMFeeEstimator.word(n).hexString) }
private func selector(_ signature: String) -> String { "0x" + Data(Data(signature.utf8).keccak256.prefix(4)).hexString }
private func baseReply(_ method: String, _ params: [JSONValue], id: UInt64) throws -> JSONValue {
    switch method {
    case "eth_chainId": return .string(Ethereum.quantity(BigUInt(id)))
    case "eth_getBlockByNumber": return .object(["baseFeePerGas": .string("0xa")])
    case "eth_maxPriorityFeePerGas": return .string("0x2")
    case "eth_getTransactionCount": return .string("0x0")
    case "eth_estimateGas": return .string("0x5208")
    case "eth_getBalance": return .string("0xde0b6b3a7640000")
    default: throw WalletError.invalid("Unexpected test method")
    }
}
private func network(_ id: UInt64) -> Chain { Chain.defaults.first { $0.id == id }! }

struct EVMNetworkTests {
    @Test func catalogAndExistingEndpointMigration() throws {
        let evm = Chain.defaults.filter(\.isEVM)
        #expect(Set(evm.map(\.id)).count == evm.count)
        #expect(Set(EVMNetworkSupport.mainstreamIDs).count == EVMNetworkSupport.mainstreamIDs.count)
        #expect(EVMNetworkSupport.mainstreamIDs.allSatisfy { id in evm.contains { $0.id == id && !$0.isTestnet } })
        for (id, symbol) in [(UInt64(252), "FRAX"), (13371, "IMX"), (592, "ASTR"), (4689, "IOTX"), (40, "TLOS"), (10001, "ETHW")] {
            #expect(network(id).symbol == symbol)
        }
        var old = network(10001); old.symbol = "BCHT"; old.rpcURL = "https://rpc-testnet.smartbch.org"
        let migrated = NetworkCatalog.mergeDefaults(into: [old])
        #expect(migrated.first?.rpcURL == network(10001).rpcURL)
        #expect(migrated.first?.symbol == "ETHW")
        old.rpcURL = "https://user-node.example/rpc"
        #expect(NetworkCatalog.mergeDefaults(into: [old]).first?.rpcURL == old.rpcURL)
        #expect(NetworkCatalog.mergeDefaults(into: migrated) == migrated)
        var ethereum = network(1); ethereum.rpcURL = "https://ethereum-rpc.publicnode.com"
        #expect(NetworkCatalog.mergeDefaults(into: [ethereum]).first?.rpcURL == "https://eth.drpc.org")
        ethereum.rpcURL = "https://custom-ethereum.example/rpc"
        #expect(NetworkCatalog.mergeDefaults(into: [ethereum]).first?.rpcURL == ethereum.rpcURL)
    }

    @Test func collidingETHWChainIDRequiresGenesis() async throws {
        for valid in [false, true] {
            let transport = FeeRPC { method, _ in
                if method == "eth_chainId" { return .string("0x2711") }
                return .object(["hash": .string(valid ? EVMNetworkSupport.expectedGenesisHashes[10001]! : "0x" + String(repeating: "0", count: 64))])
            }
            let client = RPCClient(transport: transport, chain: network(10001), isolation: "test")
            do { try await client.verifyChain(); #expect(valid) }
            catch { #expect(!valid) }
        }
    }

    @Test func priorityFeeFallbackRequiresMethodUnavailable() async throws {
        for code in [-32601, -32005] {
            let client = RPCClient(transport: FeeRPC { method, params in
                if method == "eth_maxPriorityFeePerGas" { throw WalletError.rpcRejected(code) }
                if method == "eth_gasPrice" { #expect(code == -32601); return .string("0xf") }
                return try baseReply(method, params, id: 1)
            }, chain: network(1), isolation: "test")
            do {
                let quote = try await client.feeQuote()
                #expect(code == -32601); #expect(quote.maxPriorityFee == 5); #expect(quote.maxFee == 25)
            } catch WalletError.rpcRejected(let actual) { #expect(code == -32005); #expect(actual == code) }
        }
        let client = RPCClient(transport: FeeRPC { method, _ in
            #expect(method == "eth_getBlockByNumber"); return .object(["baseFeePerGas": .string("broken")])
        }, chain: network(1), isolation: "test")
        do { _ = try await client.feeQuote(); Issue.record("Malformed base fee silently became legacy") } catch {}
    }

    @Test func opFeesAreIncludedInBalanceBudget() async throws {
        let client = RPCClient(transport: FeeRPC { method, params in
            if method == "eth_call" {
                let data = params[0]["data"]!.string!
                #expect(params[0]["to"] == .string(EVMFeeEstimator.opOracle))
                if data.hasPrefix(selector("getL1FeeUpperBound(uint256)")) { return abi(1000) }
                #expect(data.hasPrefix(selector("getOperatorFee(uint256)")))
                #expect(try BigUInt(Data(strictHex: String(data.dropFirst(10)))) == 25200)
                return abi(101)
            }
            return try baseReply(method, params, id: 8453)
        }, chain: network(8453), isolation: "test")
        let preview = try await client.prepare(sender: publicAddress, recipient: publicAddress, amount: "0.01")
        #expect(preview.additionalFees.estimated == 1101)
        #expect(preview.additionalFees.budget == 1322)
        #expect(preview.totalFeeBudget == 25200 * 22 + 1322)
        try await client.revalidate(preview)
        let poorClient = RPCClient(transport: FeeRPC { method, params in
            if method == "eth_call" { return abi(1000) }
            if method == "eth_getBalance" { return .string(Ethereum.quantity(preview.transaction.value + preview.transaction.maximumFee)) }
            return try baseReply(method, params, id: 8453)
        }, chain: network(8453), isolation: "test")
        do { _ = try await poorClient.prepare(sender: publicAddress, recipient: publicAddress, amount: "0.01"); Issue.record("L1/operator fee omitted from balance requirement") } catch {}
        let spiked = RPCClient(transport: FeeRPC { method, params in
            if method == "eth_call" { return abi(10_000) }
            return try baseReply(method, params, id: 8453)
        }, chain: network(8453), isolation: "test")
        do { try await spiked.revalidate(preview); Issue.record("Unapproved L1 fee increase accepted") } catch {}
    }

    @Test func eraVMUsesNodeGasPriceWithoutPriorityFeeMethod() async throws {
        for id: UInt64 in [324, 2741] {
            let client = RPCClient(transport: FeeRPC { method, _ in
                #expect(method == "eth_gasPrice"); return .string("0xf")
            }, chain: network(id), isolation: "test")
            let quote = try await client.feeQuote()
            #expect(quote.mode == .legacy); #expect(quote.maxPriorityFee == 0); #expect(quote.maxFee == 15)
        }
    }

    @Test func preIsthmusOracleNeedsRecognizedVersion() async throws {
        for version in ["1.3.1-beta.3", "9.0.0", "-", "1.03.1"] {
            let client = RPCClient(transport: FeeRPC { method, params in
                if method == "eth_call" {
                    let data = params[0]["data"]!.string!
                    if data.hasPrefix(selector("getL1Fee(bytes)")) { return abi(500) }
                    if data == selector("version()") {
                        let bytes = Data(version.utf8)
                        return .string("0x" + (EVMFeeEstimator.word(32) + EVMFeeEstimator.word(BigUInt(bytes.count)) + bytes + Data(repeating: 0, count: (32 - bytes.count % 32) % 32)).hexString)
                    }
                    throw WalletError.rpcRejected(3)
                }
                return try baseReply(method, params, id: 10)
            }, chain: network(10), isolation: "test")
            let tx = try EVMTransaction(chainID: 10, nonce: 0, maxPriorityFee: 1, maxFee: 2, gasLimit: 25200, to: publicAddress, value: 1)
            do {
                let fees = try await client.additionalFees(for: tx)
                #expect(version == "1.3.1-beta.3"); #expect(fees.l1DataFee == 500); #expect(fees.operatorFee == 0)
            } catch { #expect(version != "1.3.1-beta.3") }
        }
    }

    @Test func failedOracleCannotBecomeZeroFee() async throws {
        for reply in [JSONValue.string("0x01"), .null] {
            let client = RPCClient(transport: FeeRPC { _, _ in reply }, chain: network(8453), isolation: "test")
            let tx = try EVMTransaction(chainID: 8453, nonce: 0, maxPriorityFee: 1, maxFee: 2, gasLimit: 25200, to: publicAddress, value: 1)
            do { _ = try await client.additionalFees(for: tx); Issue.record("Invalid oracle data accepted") } catch {}
        }
        let client = RPCClient(transport: FeeRPC { _, _ in throw WalletError.rpcRejected(-32005) }, chain: network(8453), isolation: "test")
        let tx = try EVMTransaction(chainID: 8453, nonce: 0, maxPriorityFee: 1, maxFee: 2, gasLimit: 25200, to: publicAddress, value: 1)
        do { _ = try await client.additionalFees(for: tx); Issue.record("Quota error accepted") }
        catch WalletError.rpcRejected(let code) { #expect(code == -32005) }
    }

    @Test func mantleArsiaDoesNotDoubleCountLegacyFees() async throws {
        for active: BigUInt in [0, 1] {
            let client = RPCClient(transport: FeeRPC { method, params in
                #expect(method == "eth_call")
                let data = params[0]["data"]!.string!
                if data == selector("isArsia()") { return abi(active) }
                #expect(active == 1)
                if data.hasPrefix(selector("getL1FeeUpperBound(uint256)")) { return abi(900) }
                #expect(data.hasPrefix(selector("getOperatorFee(uint256)"))); return abi(100)
            }, chain: network(5000), isolation: "test")
            let tx = try EVMTransaction(chainID: 5000, nonce: 0, maxPriorityFee: 1, maxFee: 2, gasLimit: 25200, to: publicAddress, value: 1)
            let fees = try await client.additionalFees(for: tx)
            #expect(fees.estimated == (active == 0 ? 0 : 1000))
        }
    }

    @Test func scrollUsesSerializedTransactionIncludingSignatureSize() async throws {
        for mode in [EVMTransactionMode.eip1559, .legacy] {
            let tx = try EVMTransaction(chainID: 534352, nonce: 0, maxPriorityFee: mode == .legacy ? 0 : 1, maxFee: 2, gasLimit: 25200, to: publicAddress, value: 1, mode: mode)
            let client = RPCClient(transport: FeeRPC { method, params in
                #expect(method == "eth_call"); #expect(params[0]["to"] == .string(EVMFeeEstimator.scrollOracle))
                let data = try Data(strictHex: params[0]["data"]!.string!)
                #expect(data.prefix(4) == Data(Data("getL1Fee(bytes)".utf8).keccak256.prefix(4)))
                #expect(BigUInt(data[4..<36]) == 32)
                #expect(BigUInt(data[36..<68]) == BigUInt(tx.feeEstimationSerialized.count))
                #expect(data[68..<(68 + tx.feeEstimationSerialized.count)] == tx.feeEstimationSerialized)
                #expect(tx.feeEstimationSerialized.count > tx.unsignedSerialized.count + 60)
                return abi(700)
            }, chain: network(534352), isolation: "test")
            let fee = try await client.additionalFees(for: tx)
            #expect(fee.l1DataFee == 700); #expect(fee.budget == 840)
        }
    }

    @Test func tokenEncodingAndChainIsolationAcrossEVMNetworks() async throws {
        for id: UInt64 in [1, 56, 137, 42161, 43114, 999, 143] {
            let token = try Token(chainID: id, contract: "0x1111111111111111111111111111111111111111", symbol: "TEST", decimals: 6)
            let client = RPCClient(transport: FeeRPC { method, params in
                if method == "eth_estimateGas" {
                    #expect(params[0]["to"] == .string(token.contract)); #expect(params[0]["value"] == .string("0x0"))
                    #expect(params[0]["data"] == .string("0xa9059cbb" + String(repeating: "0", count: 24) + String(publicAddress.dropFirst(2)).lowercased() + String(repeating: "0", count: 59) + "f4241"))
                    return .string("0x10000")
                }
                if method == "eth_call" { return abi(1_000_001) }
                return try baseReply(method, params, id: id)
            }, chain: network(id), isolation: "test")
            let preview = try await client.prepare(sender: publicAddress, recipient: publicAddress, amount: "1.000001", token: token)
            #expect(preview.transaction.chainID == id); #expect(preview.transaction.value == 0)
            let wrong = try Token(chainID: id + 1, contract: token.contract, symbol: "TEST", decimals: 6)
            do { _ = try await client.prepare(sender: publicAddress, recipient: publicAddress, amount: "1", token: wrong); Issue.record("Cross-chain token accepted") } catch {}
        }
    }
}
