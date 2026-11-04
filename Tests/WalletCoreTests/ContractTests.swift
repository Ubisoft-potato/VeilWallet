import Testing
import Foundation
import BigInt
@testable import WalletCore

private struct ContractRPC: PrivateRequesting {
    let handler: @Sendable (String, [JSONValue]) throws -> JSONValue
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
        guard let method = body["method"]?.string, case .array(let params) = body["params"] else { throw WalletError.invalid("test RPC") }
        let result = try handler(method, params)
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result]))
    }
}
private let contractSender = "0x000000000000000000000000000000000000dEaD"
private let erc20Address = "0x2222222222222222222222222222222222222222"
private let wrappedAddress = "0x1111111111111111111111111111111111111111"
private func wordResult(_ n: BigUInt) -> JSONValue { .string("0x" + ContractABI.word(n).hexString) }
private func sel(_ signature: String) -> String { "0x" + Data(Data(signature.utf8).keccak256.prefix(4)).hexString }
private func contractReply(_ method: String, _ params: [JSONValue], allowance: BigUInt = 0) throws -> JSONValue {
    switch method {
    case "eth_chainId": return .string("0x1")
    case "eth_getCode": return .string("0x6000")
    case "eth_getTransactionCount": return .string("0x0")
    case "eth_getBlockByNumber": return .object(["baseFeePerGas": .string("0x1"), "timestamp": .string(Ethereum.quantity(BigUInt(Int(Date().timeIntervalSince1970))))])
    case "eth_maxPriorityFeePerGas": return .string("0x1")
    case "eth_estimateGas": return .string("0x30d40")
    case "eth_getBalance": return .string("0x56bc75e2d63100000")
    case "eth_call":
        let data = params[0]["data"]!.string!
        if data == sel("decimals()") { return wordResult(6) }
        if data == sel("factory()") { return .string("0x" + String(repeating: "0", count: 24) + String(DexClient.deployments[1]!.factory.dropFirst(2))) }
        if data == sel("WETH()") { return .string("0x" + String(repeating: "0", count: 24) + String(wrappedAddress.dropFirst(2))) }
        if data.hasPrefix(sel("getAmountsOut(uint256,address[])")) {
            let encoded = try Data(strictHex: data); let amount = BigUInt(encoded[4..<36])
            return .string("0x" + (ContractABI.word(32) + ContractABI.word(2) + ContractABI.word(amount) + ContractABI.word(2_000_000)).hexString)
        }
        if data.hasPrefix(sel("allowance(address,address)")) { return wordResult(allowance) }
        if data.hasPrefix(sel("balanceOf(address)")) { return wordResult(10_000_000) }
        return wordResult(1)
    default: Issue.record("Contract test sent an unexpected RPC method"); throw WalletError.invalid("test RPC method")
    }
}
struct ContractTests {
    let chain = Chain.defaults.first { $0.id == 1 }!
    @Test func contractPreparationRequiresCodeAndSuccessfulSimulation() async throws {
        let call = try ContractInvocation(contract: erc20Address, signature: "approve(address,uint256)", arguments: [wrappedAddress, "123"])
        for failure in ["empty-code", "revert", "false-approval"] {
            let client = RPCClient(transport: ContractRPC { method, params in
                if method == "eth_getCode", failure == "empty-code" { return .string("0x") }
                if method == "eth_call" {
                    if failure == "revert" { throw WalletError.rpcRejected(3) }
                    if failure == "false-approval" { return wordResult(0) }
                }
                return try contractReply(method, params)
            }, chain: chain, isolation: "test")
            do { _ = try await client.prepareContract(sender: contractSender, invocation: call); Issue.record("Failed contract accepted for signing") } catch {}
        }
        let client = RPCClient(transport: ContractRPC(handler: { try contractReply($0, $1) }), chain: chain, isolation: "test")
        let preview = try await client.prepareContract(sender: contractSender, invocation: call)
        #expect(preview.transaction.data == call.data); #expect(preview.transaction.value == 0)
        #expect(preview.purpose.invocation == call)
        try await client.revalidate(preview)
        let reverted = RPCClient(transport: ContractRPC { method, params in
            if method == "eth_call" { throw WalletError.rpcRejected(3) }; return try contractReply(method, params)
        }, chain: chain, isolation: "test")
        do { try await reverted.revalidate(preview); Issue.record("Changed contract execution accepted") } catch {}
        let denied = RPCClient(transport: ContractRPC { method, params in
            if method == "eth_call" { return wordResult(0) }; return try contractReply(method, params)
        }, chain: chain, isolation: "test")
        do { try await denied.revalidate(preview); Issue.record("False approval accepted during final revalidation") } catch {}
    }
    @Test func dexPinsDeploymentAndEncodesMinimumOutputAndRecipient() async throws {
        let rpc = RPCClient(transport: ContractRPC(handler: { try contractReply($0, $1) }), chain: chain, isolation: "test")
        let dex = DexClient(rpc: rpc)
        let token = try Token(chainID: 1, contract: erc20Address, symbol: "TEST", decimals: 6)
        let quote = try await dex.quote(sender: contractSender, input: nil, output: token, amount: "1", slippageBPS: 50)
        #expect(quote.minimumOut == 1_990_000); #expect(quote.path == [Ethereum.checksumAddress(wrappedAddress), token.contract])
        #expect(quote.invocation.nativeValue == 1_000_000_000_000_000_000)
        let preview = try await dex.prepareSwap(quote, sender: contractSender)
        #expect(preview.purpose.isSwap); #expect(preview.transaction.to.lowercased() == DexClient.deployments[1]?.router)
        #expect(quote.invocation.arguments[2] == contractSender)
        try await rpc.revalidate(preview)
        let wrongFactory = RPCClient(transport: ContractRPC { method, params in
            if method == "eth_call", params[0]["data"] == .string(sel("factory()")) { return wordResult(1) }; return try contractReply(method, params)
        }, chain: chain, isolation: "test")
        do { _ = try await DexClient(rpc: wrongFactory).quote(sender: contractSender, input: nil, output: token, amount: "1"); Issue.record("Foreign factory accepted") } catch {}
        for slippage: UInt32 in [0, 1001] { do { _ = try await dex.quote(sender: contractSender, input: nil, output: token, amount: "1", slippageBPS: slippage); Issue.record("Invalid slippage accepted") } catch {} }
    }
    @Test func erc20SwapRequiresSeparateExactApproval() async throws {
        let token = try Token(chainID: 1, contract: erc20Address, symbol: "TEST", decimals: 6)
        for allowance: BigUInt in [0, 1] {
            let rpc = RPCClient(transport: ContractRPC(handler: { try contractReply($0, $1, allowance: allowance) }), chain: chain, isolation: "test")
            let dex = DexClient(rpc: rpc)
            let quote = try await dex.quote(sender: contractSender, input: token, output: nil, amount: "1")
            do { _ = try await dex.prepareSwap(quote, sender: contractSender); Issue.record("Swap accepted without allowance") } catch {}
            let approval = try await dex.prepareApproval(quote, sender: contractSender)
            #expect(approval.purpose.invocation?.signature == "approve(address,uint256)")
            #expect(approval.purpose.invocation?.arguments.last == (allowance == 0 ? "1000000" : "0"))
            #expect(approval.transaction.to == token.contract)
        }
    }
}
