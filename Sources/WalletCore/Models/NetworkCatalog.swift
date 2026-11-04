import Foundation

public enum NetworkCatalog {
    public static let sourceDate = "2026-11-02"
    public static let chains: [Chain] = {
        let sepolia = Chain(id: 11155111, name: "Ethereum Sepolia", symbol: "ETH", rpcURL: "https://ethereum-sepolia-rpc.publicnode.com", isTestnet: true)
        let evm: [Chain]
        if let url = Bundle.module.url(forResource: "evm-networks", withExtension: "json"), let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode([Chain].self, from: data) { evm = result }
        else { evm = [Chain(id: 1, name: "Ethereum", symbol: "ETH", rpcURL: "https://ethereum-rpc.publicnode.com")] }
        return [sepolia] + evm + nativeChains
    }()
    public static let nativeChains: [Chain] = {
        var result = [
            native(128, "Monero", "XMR", MoneroNode.defaultURL, .monero, ["monero.ledger"], 12),
            native(0, "Bitcoin", "BTC", "https://blockstream.info/api", .bitcoin, ["btc.segwit", "btc.legacy", "btc.nested", "btc.taproot"], 8),
            native(2, "Litecoin", "LTC", "https://litecoinspace.org/api", .litecoin, AccountProfile.litecoinProfiles.map(\.id), 8),
            native(501, "Solana", "SOL", "https://api.mainnet-beta.solana.com", .solana, ["solana", "solana.legacy"], 9),
            native(195, "Tron", "TRX", "https://api.tronstack.io", .tron, ["tron"], 6),
            native(784, "Sui", "SUI", "https://graphql.mainnet.sui.io/graphql", .sui, ["sui"], 9),
            native(637, "Aptos", "APT", "https://fullnode.mainnet.aptoslabs.com/v1", .aptos, ["aptos"], 8),
            native(607, "TON", "TON", "https://toncenter.com/api/v2", .ton, ["ton.v4", "ton.v5"], 9),
            native(397, "NEAR", "NEAR", "https://rpc.mainnet.near.org", .near, ["near"], 24),
            native(5757, "Stacks", "STX", "https://api.mainnet.hiro.so", .stacks, ["stacks"], 6),
            native(1815, "Cardano", "ADA", "https://api.koios.rest/api/v1", .cardano, ["cardano"], 6),
            native(9004, "Starknet", "STRK", "https://starknet-mainnet.public.blastapi.io/rpc/v0_8", .starknet, ["starknet"], 18),
            native(194, "EOS", "EOS", "https://eos.greymass.com", .eos, ["eos"], 4),
            native(14001, "WAX", "WAXP", "https://wax.greymass.com", .eos, ["wax"], 8),
            native(354, "Polkadot · Ed25519", "DOT", "https://polkadot-rpc.publicnode.com", .polkadot, ["polkadot.ed25519"], 10),
            native(1237, "Nostr", "—", "", .nostr, ["nostr"], 0)
        ]
        let metadata: [(String, String, String, String, String, Int)] = [
            ("cosmos", "Cosmos Hub", "ATOM", "https://cosmos-rest.publicnode.com", "uatom", 6),
            ("osmosis", "Osmosis", "OSMO", "https://osmosis-rest.publicnode.com", "uosmo", 6),
            ("celestia", "Celestia", "TIA", "https://celestia-rest.publicnode.com", "utia", 6),
            ("injective", "Injective", "INJ", "https://sentry.lcd.injective.network", "inj", 18),
            ("sei.cosmos", "Sei Cosmos", "SEI", "https://rest.sei-apis.com", "usei", 6),
            ("juno", "Juno", "JUNO", "", "ujuno", 6), ("akash", "Akash", "AKT", "", "uakt", 6),
            ("secret", "Secret Network", "SCRT", "", "uscrt", 6), ("kujira", "Kujira", "KUJI", "", "ukuji", 6),
            ("stargaze", "Stargaze", "STARS", "", "ustars", 6), ("stride", "Stride", "STRD", "", "ustrd", 6),
            ("neutron", "Neutron", "NTRN", "", "untrn", 6), ("dydx", "dYdX", "DYDX", "", "adydx", 18),
            ("noble", "Noble", "USDC", "", "uusdc", 6), ("persistence", "Persistence", "XPRT", "", "uxprt", 6),
            ("axelar", "Axelar", "AXL", "", "uaxl", 6), ("band", "Band", "BAND", "", "uband", 6),
            ("iris", "IRISnet", "IRIS", "", "uiris", 6), ("kava.cosmos", "Kava Cosmos", "KAVA", "", "ukava", 6),
            ("terra", "Terra", "LUNA", "", "uluna", 6), ("terra.classic", "Terra Classic", "LUNC", "", "uluna", 6),
            ("chihuahua", "Chihuahua", "HUAHUA", "", "uhuahua", 6), ("sentinel", "Sentinel", "DVPN", "", "udvpn", 6),
            ("comdex", "Comdex", "CMDX", "", "ucmdx", 6)
        ]
        result += metadata.enumerated().map { index, row in
            native(UInt64(100_000 + index), row.1, row.2, row.3, .cosmos, [row.0], row.5, denomination: row.4)
        }
        return result
    }()
    static func native(_ index: UInt64, _ name: String, _ symbol: String, _ rpc: String, _ family: NetworkFamily, _ profiles: [String], _ decimals: Int, denomination: String? = nil) -> Chain {
        Chain(id: 0x8000000000000000 | index, name: name, symbol: symbol, rpcURL: rpc, family: family, profiles: profiles, decimals: decimals, denomination: denomination)
    }
    public static func mergeDefaults(into stored: [Chain]) -> [Chain] {
        let catalog = Dictionary(uniqueKeysWithValues: chains.map { ($0.id, $0) })
        let migrated = stored.map { original in
            guard let current = catalog[original.id] else { return original }
            var updated = original
            if original.family == .tron, original.rpcURL == "https://api.trongrid.io" { updated.rpcURL = current.rpcURL }
            guard original.isEVM else { return updated }
            // Fix known shipped mistakes only; never replace a user's custom endpoint.
            if EVMNetworkSupport.previousDefaultRPCs[original.id]?.contains(original.rpcURL) == true { updated.rpcURL = current.rpcURL }
            updated.name = current.name; updated.symbol = current.symbol; updated.decimalsHint = current.decimalsHint
            return updated
        }
        let IDs = Set(migrated.map(\.id))
        return migrated + chains.filter { !IDs.contains($0.id) }
    }
}
