import Testing
import Foundation
import BigInt
@testable import WalletCore

private struct MockRPC: PrivateRequesting {
    let handler: @Sendable (String, [JSONValue]) throws -> JSONValue
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
        guard let method = body["method"]?.string, case .array(let params) = body["params"] else { throw WalletError.invalid("Invalid test request") }
        let result = try handler(method, params)
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result]))
    }
}
struct RPCTests {
    let address = "0x000000000000000000000000000000000000dEaD"
    @Test func rejectsWrongChainBeforeSigning() async throws {
        let mock = MockRPC { _, _ in .string("0x1") }
        let client = RPCClient(transport: mock, chain: Chain.defaults[0], isolation: "test")
        do { try await client.verifyChain(); Issue.record("Wrong chain accepted") } catch {}
    }
    @Test func refusesZeroAddressAndExcessivePrecision() async throws {
        let mock = MockRPC { _, _ in Issue.record("Invalid input made network request"); return .null }
        let client = RPCClient(transport: mock, chain: Chain.defaults[0], isolation: "test")
        do { _ = try await client.prepare(sender: address, recipient: "0x" + String(repeating: "0", count: 40), amount: "1"); Issue.record("Zero recipient accepted") } catch {}
        do { _ = try await client.prepare(sender: address, recipient: address, amount: "1.0000000000000000001"); Issue.record("Precision accepted") } catch {}
    }
    @Test func estimatesAndEncodesNativeTransfer() async throws {
        let mock = MockRPC { method, _ in
            switch method {
            case "eth_chainId": return .string("0xaa36a7")
            case "eth_getTransactionCount": return .string("0x2")
            case "eth_getBlockByNumber": return .object(["baseFeePerGas": .string("0x3b9aca00")])
            case "eth_maxPriorityFeePerGas": return .string("0x3b9aca00")
            case "eth_estimateGas": return .string("0x5208")
            case "eth_getBalance": return .string("0xde0b6b3a7640000")
            default: throw WalletError.invalid("Unexpected method")
            }
        }
        let client = RPCClient(transport: mock, chain: Chain.defaults[0], isolation: "test")
        let preview = try await client.prepare(sender: address, recipient: address, amount: "0.01")
        #expect(preview.transaction.nonce == 2)
        #expect(preview.transaction.maxFee == 3_000_000_000)
        #expect(preview.transaction.gasLimit == 25200)
        #expect(preview.transaction.value == 10_000_000_000_000_000)
        try await client.revalidate(preview)
    }
    @Test func refusesInsufficientBalance() async throws {
        let mock = MockRPC { method, _ in
            switch method {
            case "eth_chainId": return .string("0xaa36a7")
            case "eth_getTransactionCount", "eth_getBalance": return .string("0x0")
            case "eth_getBlockByNumber": return .object(["baseFeePerGas": .string("0x1")])
            case "eth_maxPriorityFeePerGas": return .string("0x1")
            case "eth_estimateGas": return .string("0x5208")
            default: throw WalletError.invalid("Unexpected method")
            }
        }
        do {
            _ = try await RPCClient(transport: mock, chain: Chain.defaults[0], isolation: "test").prepare(sender: address, recipient: address, amount: "1")
            Issue.record("Insufficient balance accepted")
        } catch {}
    }
    @Test func rejectsUnapprovedRPCMethod() async throws {
        let mock = MockRPC { _, _ in Issue.record("Disallowed method was sent"); return .null }
        do { _ = try await RPCClient(transport: mock, chain: Chain.defaults[0], isolation: "test").call("eth_sign", params: []); Issue.record("eth_sign allowed") } catch {}
    }
}

extension RPCTests {
    @Test func legacyFeeNetworksUseGasPriceWithout1559Fields() async throws {
        let mock = MockRPC { method, params in
            switch method {
            case "eth_chainId": return .string("0xaa36a7")
            case "eth_getTransactionCount": return .string("0x0")
            case "eth_getBlockByNumber": return .object(["number": .string("0x1")])
            case "eth_gasPrice": return .string("0x3b9aca00")
            case "eth_estimateGas":
                #expect(params[0]["gasPrice"] == .string("0x3b9aca00"))
                #expect(params[0]["maxFeePerGas"] == nil)
                return .string("0x5208")
            case "eth_getBalance": return .string("0xde0b6b3a7640000")
            default: Issue.record("Unexpected RPC method"); throw WalletError.invalid("method")
            }
        }
        let preview = try await RPCClient(transport: mock, chain: Chain.defaults[0], isolation: "test").prepare(sender: address, recipient: address, amount: "0.01")
        #expect(preview.transaction.mode == .legacy)
        #expect(preview.transaction.maxPriorityFee == 0)
        #expect(preview.transaction.maxFee == 1_000_000_000)
    }
}
