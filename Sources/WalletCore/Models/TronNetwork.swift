import Foundation

/// TRON addresses share a format across networks. Identity must therefore bind
/// the explicit network ID, testnet flag, and expected genesis block.
public enum TronNetwork {
    public static let nileID: UInt64 = 0x8000000000000000 | 1_000_195
    public static let nile = Chain(id: nileID, name: "TRON Nile", symbol: "TRX", rpcURL: "https://nile.trongrid.io", isTestnet: true, family: .tron, profiles: ["tron"], decimals: 6)

    static func isTron(_ id: UInt64) -> Bool { id == TronAddress.chainID || id == nileID }

    static func genesis(for chain: Chain) throws -> String {
        guard chain.family == .tron else { throw WalletError.invalid(L("tron.network_mismatch")) }
        if chain.id == TronAddress.chainID, !chain.isTestnet {
            return "00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc"
        }
        if chain.id == nileID, chain.isTestnet {
            return "0000000000000000d698d4192c56cb6be724a558448e2684802de4d6cd8690dc"
        }
        throw WalletError.invalid(L("tron.network_mismatch"))
    }

    static func v2Deployment(_ id: UInt64) throws -> (router: String, factory: String, wrapped: String) {
        if id == TronAddress.chainID {
            return (TronDexClient.v2Router, TronDexClient.v2Factory, TronDexClient.wrapped)
        }
        if id == nileID {
            return ("TMn1qrmYUMSTXo9babrJLzepKZoPC7M6Sy", "THomLGMLhAjMecQf9FQjbZ8a1RtwsZLrGE", "TYsbWxNnyTgsZaTFaue9hqpxkU3Fkco94a")
        }
        throw WalletError.invalid(L("tron.network_mismatch"))
    }
}
