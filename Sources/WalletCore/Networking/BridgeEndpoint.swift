import Foundation
import BigInt

enum BridgeEndpoint: Sendable {
    case evm(RPCClient), tron(TronContractClient)
    var chain: Chain { switch self { case .evm(let c): return c.chain; case .tron(let c): return c.chain } }
    func read(_ address: String, _ signature: String, _ args: [String] = []) async throws -> Data {
        switch self {
        case .evm(let c): return try await c.readContract(ContractInvocation(contract: address, signature: signature, arguments: args))
        case .tron(let c): return try await c.read(TronInvocation(contract: address, signature: signature, arguments: args))
        }
    }
    func uint(_ address: String, _ signature: String, _ args: [String] = []) async throws -> BigUInt { try ContractABI.uint(await read(address, signature, args)) }
    func address(_ target: String, _ signature: String, _ args: [String] = []) async throws -> String {
        let evm = try ContractABI.address(await read(target, signature, args))
        return try chain.family == .tron ? TronAddress.base58(evm) : evm
    }
    func balance(_ owner: String, token: Token) async throws -> BigUInt {
        switch self { case .evm(let c): return try await c.balance(address: owner, token: token); case .tron(let c): return try await c.balance(address: owner, token: token) }
    }
    func allowance(owner: String, token: Token, spender: String) async throws -> BigUInt {
        try await uint(token.contract, "allowance(address,address)", [Self.evmAddress(owner, chain: chain), Self.evmAddress(spender, chain: chain)])
    }
    static func evmAddress(_ value: String, chain: Chain) throws -> String {
        if chain.family == .tron { return try TronAddress.evm(value) }
        guard Ethereum.validateAddress(value) else { throw WalletError.invalid(L("message.invalid_bridge_evm_address")) }; return Ethereum.checksumAddress(value)
    }
    static func word(_ value: String, networkID: UInt64) throws -> String {
        let address = try networkID == TronAddress.chainID ? TronAddress.evm(value) : value
        guard Ethereum.validateAddress(address), BigUInt(try Data(strictHex: address)) > 0 else { throw WalletError.invalid(L("message.bridge_recipient_must_not_be_the_zero_address")) }
        return "0x" + (Data(repeating: 0, count: 12) + (try Data(strictHex: address))).hexString
    }
    static func same(_ a: String, _ b: String, chain: Chain) -> Bool { chain.family == .tron ? a == b : a.lowercased() == b.lowercased() }
}

public struct BridgeClient: Sendable {
    let transport: any PrivateRequesting
    let chains: [Chain]
    let isolation: String
    let noncePolicy: EVMNoncePolicy?
    public init(transport: any PrivateRequesting, chains: [Chain], isolation: String, noncePolicy: EVMNoncePolicy? = nil) { self.transport = transport; self.chains = chains; self.isolation = isolation; self.noncePolicy = noncePolicy }
    func endpoint(_ id: UInt64) throws -> BridgeEndpoint {
        guard let chain = chains.first(where: { $0.id == id }), BridgeCatalog.on(id).isEmpty == false else { throw WalletError.invalid(L("message.this_network_has_no_bridge_integration")) }
        if chain.family == .tron { return .tron(TronContractClient(transport: transport, chain: chain, isolation: isolation + ":bridge:" + String(id))) }
        guard chain.isEVM else { throw WalletError.invalid(L("message.unsupported_bridge_protocol")) }
        return .evm(RPCClient(transport: transport, chain: chain, isolation: isolation + ":bridge:" + String(id), noncePolicy: noncePolicy))
    }
}
