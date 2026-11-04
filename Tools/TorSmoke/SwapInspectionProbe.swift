import Foundation
import WalletCore

/// Read-only diagnosis. Never prints transaction/account identifiers or raw calldata.
@MainActor enum SwapInspectionProbe {
    static func run(gate: NetworkGate) async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--inspect-bsc-swap"),
              CommandLine.arguments.indices.contains(index + 1) else { throw WalletError.invalid("Missing transaction hash") }
        let hash = CommandLine.arguments[index + 1]
        guard hash.hasPrefix("0x"), try Data(strictHex: hash).count == 32 else { throw WalletError.invalid("Invalid transaction hash") }
        let chain = Chain.defaults.first { $0.id == 56 }!
        let rpc = RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: UUID().uuidString)
        try await rpc.verifyChain()
        let transaction = try await rpc.call("eth_getTransactionByHash", params: [.string(hash)])
        guard let from = transaction["from"]?.string, let to = transaction["to"]?.string,
              let input = transaction["input"]?.string else { throw WalletError.invalid("Transaction unavailable") }
        let activity = Activity(walletID: UUID(), chainID: 56, hash: hash, to: to, amount: "read-only diagnosis", symbol: chain.symbol)
        let result = try await rpc.observe(activity: activity)
        TorSmoke.output("BSC transaction: " + result.phase.rawValue + "; confirmations=" + String(result.confirmations ?? 0))
        let data = try Data(strictHex: input)
        guard data.count == 68, Data(data.prefix(4)).hexString == "095ea7b3" else {
            TorSmoke.output("Call is not standard ERC-20 approve(address,uint256); no transaction sent")
            return
        }
        let spender = "0x" + Data(data[16..<36]).hexString
        let amount = try ContractABI.uint(Data(data[36..<68]))
        let token = TokenCatalog.all.first { $0.chainID == 56 && $0.contract.lowercased() == to.lowercased() }
        let venues = DexCatalog.on(56).filter { $0.router.lowercased() == spender.lowercased() }.map(\.name)
        TorSmoke.output("Call: ERC-20 approve (authorization only, not a swap)")
        TorSmoke.output("Token: " + (token?.symbol ?? "not in preset catalog") + "; spender: " + (venues.isEmpty ? "not a pinned BSC DEX router" : venues.joined(separator: ", ")))
        if let token {
            let allowanceCall = try ContractInvocation(contract: to, signature: "allowance(address,address)", arguments: [from, spender])
            let remaining = try ContractABI.uint(await rpc.readContract(allowanceCall))
            TorSmoke.output("Approved amount: " + Ethereum.formatUnits(amount, decimals: token.decimals, precision: token.decimals))
            TorSmoke.output("Current allowance: " + Ethereum.formatUnits(remaining, decimals: token.decimals, precision: token.decimals))
        }
        TorSmoke.output("Read-only diagnosis complete; no signing or broadcast performed")
    }
}
