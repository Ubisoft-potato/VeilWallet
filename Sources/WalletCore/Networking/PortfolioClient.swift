import Foundation
import BigInt

public struct PortfolioClient: Sendable {
    let transport: any PrivateRequesting
    let isolation: String
    public init(transport: any PrivateRequesting, isolation: String) { self.transport = transport; self.isolation = isolation }
    public func balance(_ query: AssetQuery) async throws -> BigUInt {
        guard query.automatic else { throw WalletError.invalid(L("message.this_account_requires_a_local_scan_account_link_or_configured")) }
        try Task.checkCancellation()
        let chain = query.chain, sender = query.account.networkAddress
        let key = isolation + ":" + query.walletID.uuidString + ":" + String(chain.id)
        if chain.isEVM {
            let rpc = RPCClient(transport: transport, chain: chain, isolation: key)
            if let token = query.token {
                let decimals = try await ContractABI.uint(rpc.readContract(ContractInvocation(contract: token.contract, signature: "decimals()", arguments: [])))
                guard decimals == BigUInt(token.decimals) else { throw WalletError.invalid(L("message.on_chain_token_decimals_differ_from_local_configuration_a_potentially")) }
            } else { try await rpc.verifyChain() }
            return try await rpc.balance(address: sender, token: query.token)
        }
        if let token = query.token {
            guard chain.family == .tron else { throw WalletError.invalid(L("message.token_balances_are_unsupported_for_this_protocol")) }
            let client = TronContractClient(transport: transport, chain: chain, isolation: key)
            // Share chain / code checks only within this logical read. There is
            // no cross-node or cross-session verification cache.
            try await client.verifyChain(); try await client.verifyCode(token.contract)
            let decimals = try await ContractABI.uint(client.simulate(TronInvocation(contract: token.contract, signature: "decimals()", arguments: []), sender: token.contract).output)
            guard decimals == BigUInt(token.decimals) else { throw WalletError.invalid(L("message.on_chain_trc20_decimals_differ_from_local_configuration")) }
            return try await ContractABI.uint(client.simulate(TronInvocation(contract: token.contract, signature: "balanceOf(address)", arguments: [TronAddress.evm(sender)]), sender: token.contract).output)
        }
        return try await NativeBalanceClient(transport: transport, chain: chain, isolation: key).balance(account: query.account)
    }
}
