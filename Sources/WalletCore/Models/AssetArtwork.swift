import Foundation

public enum AssetArtwork {
    public static func url(_ key: String) -> URL? {
        guard !key.isEmpty, key.count <= 40, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let alias = ["usdt0":"usdt", "wtrx":"trx", "rbtc":"btc", "waxp":"wax", "lunc":"luna", "sonic":"s", "gnosis":"xdai", "matic":"pol"]
        return Bundle.module.url(forResource: "asset-" + key.lowercased(), withExtension: "png") ?? alias[key.lowercased()].flatMap { Bundle.module.url(forResource: "asset-" + $0, withExtension: "png") }
    }
    public static func nativeKey(_ chain: Chain) -> String { chain.symbol.lowercased() }
    public static func networkKey(_ chain: Chain) -> String {
        if !chain.isEVM { return nativeKey(chain) }
        return [1:"eth", 56:"bnb", 137:"matic", 42161:"arbitrum", 10:"optimism", 8453:"base", 43114:"avax", 324:"zksync", 59144:"linea", 534352:"scroll", 5000:"mantle", 100:"gnosis", 196:"okb", 146:"sonic", 999:"hype", 80094:"bera" ][chain.id] ?? nativeKey(chain)
    }
}
