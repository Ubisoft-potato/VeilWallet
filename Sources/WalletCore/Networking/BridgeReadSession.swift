import Foundation
import BigInt

/// Scoped to one quote/revalidation. Verify each network and each distinct
/// contract once, instead of doing three remote requests for every getter.
actor BridgeReadSession {
    let endpoint: BridgeEndpoint
    nonisolated let chain: Chain
    private var verified = false
    private var contracts = Set<String>()
    init(_ endpoint: BridgeEndpoint) { self.endpoint = endpoint; chain = endpoint.chain }
    func read(_ address: String, _ signature: String, _ args: [String] = []) async throws -> Data {
        if !verified {
            switch endpoint { case .evm(let rpc): try await rpc.verifyChain(); case .tron(let tron): try await tron.verifyChain() }
            verified = true
        }
        let key = chain.family == .tron ? address : address.lowercased()
        if !contracts.contains(key) {
            switch endpoint { case .evm(let rpc): try await rpc.verifyContract(address); case .tron(let tron): try await tron.verifyCode(address) }
            contracts.insert(key)
        }
        switch endpoint {
        case .evm(let rpc): return try await rpc.simulate(ContractInvocation(contract: address, signature: signature, arguments: args), sender: nil)
        case .tron(let tron): return try await tron.simulate(TronInvocation(contract: address, signature: signature, arguments: args), sender: address).output
        }
    }
    func uint(_ address: String, _ signature: String, _ args: [String] = []) async throws -> BigUInt { try ContractABI.uint(await read(address, signature, args)) }
    func address(_ target: String, _ signature: String, _ args: [String] = []) async throws -> String {
        let evm = try ContractABI.address(await read(target, signature, args))
        return try chain.family == .tron ? TronAddress.base58(evm) : evm
    }
    func balance(_ owner: String, token: Token) async throws -> BigUInt { try await uint(token.contract, "balanceOf(address)", [BridgeEndpoint.evmAddress(owner, chain: chain)]) }
    func allowance(owner: String, token: Token, spender: String) async throws -> BigUInt { try await uint(token.contract, "allowance(address,address)", [BridgeEndpoint.evmAddress(owner, chain: chain), BridgeEndpoint.evmAddress(spender, chain: chain)]) }
}
