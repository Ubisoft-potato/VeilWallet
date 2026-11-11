import Foundation
import BigInt

/// Presentation groups use reviewed catalog identities, never a user supplied
/// ticker alone. Wrapped, legacy and bridged tickers retain their own groups.
public struct PortfolioAssetGroup: Identifiable, Sendable {
    private static let pinnedChains = Dictionary(uniqueKeysWithValues: Chain.defaults.map { ($0.id, $0) })
    public let id: String
    public let holdings: [AssetQuery]
    public var symbol: String { holdings[0].symbol }
    public var networks: [Chain] {
        var seen = Set<UInt64>()
        return holdings.map(\.chain).filter { seen.insert($0.id).inserted }
    }
    public static func groups(_ queries: [AssetQuery]) -> [Self] {
        var order: [String] = [], members: [String: [AssetQuery]] = [:], seen = Set<String>()
        for query in queries where seen.insert(holdingID(query)).inserted {
            let key = query.walletID.uuidString + ":" + assetID(query)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(query)
        }
        return order.map { Self(id: $0, holdings: members[$0]!) }
    }
    private static func assetID(_ query: AssetQuery) -> String {
        let chain = query.chain
        let pinned = pinnedChains[chain.id]
        let trusted = !chain.isTestnet && pinned?.isTestnet == false && pinned?.family == chain.family && pinned?.symbol == chain.symbol && pinned?.decimals == chain.decimals && pinned?.denomination == chain.denomination
        if trusted {
            if let token = query.token, token.chainID == chain.id,
               let preset = TokenCatalog.preset(for: token), preset.symbol == token.symbol, preset.decimals == token.decimals {
                // Pegged deployments remain explicit in the expanded rows.
                // USDC on a native network shares the reviewed coin identity.
                if token.symbol == "USDC" { return "coin:coingecko:usd-coin:USDC" }
                return "preset:" + preset.symbol
            }
            if query.token == nil, let key = MarketPriceCatalog.key(chain: chain) {
                return "coin:" + key + ":" + chain.symbol
            }
        }
        // Test networks, custom networks, unknown contracts and mismatched
        // metadata cannot borrow another asset's identity or mainnet total.
        return ["local", String(chain.id), chain.family.rawValue, String(chain.isTestnet), query.token?.id ?? "native", query.symbol, String(query.decimals)].joined(separator: ":")
    }
    static func holdingID(_ query: AssetQuery) -> String {
        let address = query.chain.family == .litecoin ? ((try? Litecoin.addressInfo(query.account.networkAddress).canonicalAddress) ?? query.account.networkAddress) : (query.chain.isEVM ? query.account.networkAddress.lowercased() : query.account.networkAddress)
        return [query.walletID.uuidString, String(query.chain.id), address, query.token?.id ?? "native", query.symbol, String(query.decimals)].joined(separator: ":")
    }
}

public struct PortfolioAssetGroupSummary: Sendable {
    public let decimals: Int
    public let balance: BigUInt?
    public let unknownBalances: Int
    public let historicalBalances: Int
    public let valuation: PortfolioUSD
    public let minimumPrice: BigUInt?
    public let maximumPrice: BigUInt?
    public let missingPrices: Int
    public let historicalPrices: Bool
    public var displayBalance: String { balance.map { Ethereum.formatUnits($0, decimals: decimals, precision: decimals) } ?? "—" }
    public init(group: PortfolioAssetGroup, balances: [AssetBalanceSnapshot], prices: [MarketPriceSnapshot], balanceMaxAge: TimeInterval, now: Date = Date()) {
        let records = Dictionary(balances.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let quotes = Dictionary(prices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        decimals = group.holdings.map(\.decimals).filter { (0...36).contains($0) }.max() ?? 0
        var total: BigUInt = 0, known = 0, unknown = 0, historical = 0, missing = 0, oldPrice = false
        var units: [BigUInt] = []
        for query in group.holdings {
            if (0...36).contains(query.decimals), let snapshot = records[query.id], snapshot.matches(query), let amount = snapshot.balance, amount.bitWidth <= 256 {
                total += amount * BigUInt(10).power(decimals - query.decimals); known += 1
                if snapshot.error != nil || now.timeIntervalSince(snapshot.updatedAt ?? .distantPast) > balanceMaxAge { historical += 1 }
            } else { unknown += 1 }
            if let key = MarketPriceCatalog.key(chain: query.chain, token: query.token), let record = quotes[key], let quote = record.quote, quote.matches(query), let price = quote.units {
                units.append(price)
                if record.error != nil || !quote.isFresh(at: now) { oldPrice = true }
            } else { missing += 1 }
        }
        balance = known > 0 ? total : nil; unknownBalances = unknown; historicalBalances = historical
        minimumPrice = units.min(); maximumPrice = units.max(); missingPrices = missing; historicalPrices = oldPrice
        valuation = PortfolioUSD(queries: group.holdings, balances: balances, prices: prices, balanceMaxAge: balanceMaxAge, now: now)
    }
}
