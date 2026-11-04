import Foundation
import WalletCore

@MainActor enum TransactionProbe {
    static func run(gate: NetworkGate) async throws {
        for id: UInt64 in [1, 56] {
            let chain = Chain.defaults.first { $0.id == id }!
            let rpc = RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: UUID().uuidString)
            try await rpc.verifyChain()
            let head = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
            guard let text = head["number"]?.string else { throw WalletError.invalid("Missing public chain height") }
            let number = try Ethereum.decodeQuantity(text)
            guard number > 32 else { throw WalletError.invalid("Public chain head too low") }
            var checked = false
            for offset in 20..<25 {
                let block = try await rpc.call("eth_getBlockByNumber", params: [.string(Ethereum.quantity(number - .init(offset))), .bool(false)])
                guard case .array(let transactions) = block["transactions"] else { throw WalletError.invalid("Public block lacks transaction list") }
                guard let hash = transactions.first?.string else { continue }
                let publicTransaction = try await rpc.call("eth_getTransactionByHash", params: [.string(hash)])
                guard let from = publicTransaction["from"]?.string else { throw WalletError.invalid("Public transaction lacks sender") }
                let item = Activity(walletID: UUID(), chainID: id, hash: hash, to: publicTransaction["to"]?.string ?? from, amount: "public receipt probe", symbol: chain.symbol)
                let result = try await rpc.observe(activity: item)
                guard [.confirmed, .failed].contains(result.phase), (result.confirmations ?? 0) >= rpc.confirmationThreshold else { throw WalletError.invalid("Canonical receipt confirmation probe failed") }
                _ = try await rpc.nonceState(sender: from)
                checked = true; break
            }
            guard checked else { throw WalletError.invalid("No public transaction in bounded receipt probe") }
            TorSmoke.output("PASS: " + chain.name + " canonical receipt / confirmation / nonce over Tor (public transaction; identifiers omitted)")
        }
    }
}
