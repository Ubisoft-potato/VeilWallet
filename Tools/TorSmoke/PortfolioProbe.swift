import Foundation
import WalletCore

@MainActor enum PortfolioProbe {
    static func run(gate: NetworkGate) async throws {
        let publicAddress = "0x000000000000000000000000000000000000dEaD"
        let client = PortfolioClient(transport: TorTransport(gate: gate), isolation: "asset-probe-" + UUID().uuidString)
        let walletID = UUID()
        let ids: Set<UInt64> = [1,56,TronAddress.chainID]
        var checked = 0
        for chain in Chain.defaults.filter({ ids.contains($0.id) }) {
            let account = WalletAccount(profileID: chain.isEVM ? "evm" : "tron", address: chain.isEVM ? publicAddress : try TronAddress.base58(publicAddress))
            for preset in TokenCatalog.all.filter({ $0.chainID == chain.id }) {
                do {
                    _ = try await client.balance(.init(walletID: walletID, chain: chain, account: account, token: preset.token))
                    checked += 1
                    TorSmoke.output("PASS: " + chain.name + " / " + preset.symbol + " precision, code and balance via Tor (public fixture; balance omitted)")
                } catch {
                    TorSmoke.output("UNAVAILABLE: " + chain.name + " / " + preset.symbol + " · " + error.localizedDescription)
                    throw error
                }
            }
        }
        guard checked >= 15 else { throw WalletError.invalid("Preset probe did not cover expected EVM/TRON fixtures") }
        TorSmoke.output("PASS: " + String(checked) + " chain-specific preset checks; no signatures or broadcasts")
    }
}
