import Foundation
import WalletCore

@MainActor enum MarketPriceProbe {
    static func run(gate: NetworkGate) async throws {
        let keys = MarketPriceCatalog.requestKeys()
        let prices = try await MarketPriceClient(transport: TorTransport(gate: gate), isolation: "public-market-probe:" + UUID().uuidString).fetch(keys: keys)
        let required = ["coingecko:bitcoin", "coingecko:ethereum", "coingecko:litecoin", "coingecko:monero", "coingecko:solana", "coingecko:tron", "coingecko:binancecoin", "ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7", "bsc:0x55d398326f99059ff775485246999027b3197955", "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"]
        struct Row: Encodable { let key: String; let available: Bool; let fresh: Bool; let decimals: Int? }
        let rows = prices.map { Row(key: $0.id, available: $0.quote != nil, fresh: $0.quote?.isFresh() == true, decimals: $0.quote?.tokenDecimals) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let index = CommandLine.arguments.firstIndex(of: "--market-report"), CommandLine.arguments.indices.contains(index + 1) {
            try encoder.encode(rows).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        TorSmoke.output("Market prices over Tor: \(rows.filter(\.available).count)/\(rows.count) available; \(rows.filter(\.fresh).count) fresh; no wallet data submitted")
        for key in required {
            guard rows.contains(where: { $0.key == key && $0.available && $0.fresh }) else { throw WalletError.invalid("Required public market quote unavailable: " + key) }
        }
        TorSmoke.output("PASS: BTC / ETH / LTC / XMR / SOL / TRX / BNB and ETH / BSC / TRON USDT market prices")
    }
}
