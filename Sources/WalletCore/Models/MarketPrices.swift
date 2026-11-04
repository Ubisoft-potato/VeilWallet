import Foundation
import BigInt

public struct MarketNetwork: Codable, Sendable {
    public let chainID: UInt64
    public let family: NetworkFamily
    public let nativeSymbol: String
    public let nativeDecimals: Int
    public let nativePriceID: String?
    public let tokenNamespace: String?
}

public enum MarketPriceCatalog {
    public static let networks: [MarketNetwork] = {
        struct Catalog: Decodable { let networks: [MarketNetwork] }
        guard let url = Bundle.module.url(forResource: "market-prices", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              Set(catalog.networks.map(\.chainID)).count == catalog.networks.count else { return [] }
        return catalog.networks
    }()
    public static func key(chain: Chain, token: Token? = nil) -> String? {
        guard !chain.isTestnet, let pinned = Chain.defaults.first(where: { $0.id == chain.id }), !pinned.isTestnet,
              chain.family == pinned.family, chain.symbol == pinned.symbol, chain.decimals == pinned.decimals,
              let network = networks.first(where: { $0.chainID == chain.id }), network.family == chain.family,
              network.nativeSymbol == chain.symbol, network.nativeDecimals == chain.decimals else { return nil }
        if let token {
            guard token.chainID == chain.id, let namespace = network.tokenNamespace else { return nil }
            return namespace + ":" + (chain.family == .tron ? token.contract : token.contract.lowercased())
        }
        return network.nativePriceID
    }
    /// The same built-in list is fetched for every wallet, regardless of its
    /// balances or derived addresses. Only explicitly added contracts extend it.
    public static func requestKeys(customTokens: [Token] = []) -> [String] {
        let chains = Dictionary(uniqueKeysWithValues: Chain.defaults.map { ($0.id, $0) })
        let native = Chain.defaults.compactMap { key(chain: $0) }
        let tokens = TokenCatalog.merged(with: customTokens).compactMap { token in chains[token.chainID].flatMap { key(chain: $0, token: token) } }
        return Array(Set(native + tokens)).sorted()
    }
}

/// USD uses 18 decimal fixed-point units. Neither balances nor valuations are
/// converted to binary floating point, including while aggregating tiny assets.
public enum USDValue {
    public static let scale = BigUInt(10).power(18)
    public static func priceUnits(_ value: Decimal) throws -> BigUInt {
        guard !value.isNaN, value > 0, value <= Decimal(string: "1000000000000000")! else { throw WalletError.invalid(L("message.invalid_market_price")) }
        var number = value
        let text = NSDecimalString(&number, Locale(identifier: "en_US_POSIX"))
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }), let whole = BigUInt(parts[0]) else { throw WalletError.invalid(L("message.invalid_market_price_format")) }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let padded = String(fraction.prefix(18)) + String(repeating: "0", count: max(0, 18 - fraction.count))
        let result = whole * scale + (BigUInt(padded) ?? 0)
        guard result > 0 else { throw WalletError.invalid(L("message.the_market_price_is_below_the_supported_precision")) }; return result
    }
    public static func holding(balance: BigUInt, decimals: Int, price: BigUInt) -> BigUInt? {
        guard (0...36).contains(decimals), balance.bitWidth <= 256, price > 0, price <= BigUInt(10).power(33) else { return nil }
        return balance * price / BigUInt(10).power(decimals)
    }
    public static func formatted(_ units: BigUInt, unitPrice: Bool = false, positiveHolding: Bool = false) -> String {
        if units == 0 { return positiveHolding ? "<$0.01" : "$0.00" }
        if !unitPrice, units < scale / 100 { return "<$0.01" }
        let digits = unitPrice ? (units >= scale * 100 ? 2 : (units < scale / 100_000_000 ? 18 : 8)) : 2
        let factor = BigUInt(10).power(18 - digits), rounded = (units + factor / 2) / factor
        let divisor = BigUInt(10).power(digits)
        let whole = String(rounded / divisor), fraction = String(rounded % divisor)
        var tail = String(repeating: "0", count: digits - fraction.count) + fraction
        while tail.count > 2, tail.last == "0" { tail.removeLast() }
        var grouped = ""
        for (index, character) in whole.reversed().enumerated() { if index > 0, index % 3 == 0 { grouped.append(",") }; grouped.append(character) }
        return "$" + String(grouped.reversed()) + "." + tail
    }
}

public struct MarketPrice: Codable, Sendable {
    public let key: String
    public let usdUnits: String
    public let sourceTimestamp: Date
    public let fetchedAt: Date
    public let tokenDecimals: Int?
    public var units: BigUInt? { BigUInt(usdUnits).flatMap { $0 > 0 && $0 <= BigUInt(10).power(33) ? $0 : nil } }
    public init(key: String, units: BigUInt, sourceTimestamp: Date, fetchedAt: Date, tokenDecimals: Int?) {
        self.key = key; usdUnits = String(units); self.sourceTimestamp = sourceTimestamp; self.fetchedAt = fetchedAt; self.tokenDecimals = tokenDecimals
    }
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(sourceTimestamp), fetchedAge = now.timeIntervalSince(fetchedAt)
        return age >= -120 && age <= 900 && fetchedAge >= -120 && fetchedAge <= 900
    }
    public func matches(_ query: AssetQuery) -> Bool {
        guard MarketPriceCatalog.key(chain: query.chain, token: query.token) == key, units != nil else { return false }
        return query.token == nil || tokenDecimals == query.decimals
    }
}
public struct MarketPriceSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let quote: MarketPrice?
    public let attemptedAt: Date
    public let error: String?
    public init(key: String, quote: MarketPrice?, error: String?, previous: MarketPriceSnapshot? = nil, now: Date = Date()) {
        id = key; self.quote = quote?.key == key ? quote : (previous?.id == key ? previous?.quote : nil)
        attemptedAt = now; self.error = error
    }
}
public struct PortfolioUSD: Sendable {
    public private(set) var total: BigUInt = 0
    public private(set) var pricedHoldings = 0
    public private(set) var unpricedHoldings = 0
    public private(set) var unknownBalances = 0
    public private(set) var knownBalances = 0
    public private(set) var historicalHoldings = 0
    public private(set) var historicalBalances = 0
    public var displayTotal: String { pricedHoldings == 0 && (unpricedHoldings > 0 || knownBalances == 0) ? "—" : USDValue.formatted(total, positiveHolding: pricedHoldings > 0) }
    public init(queries: [AssetQuery], balances: [AssetBalanceSnapshot], prices: [MarketPriceSnapshot], balanceMaxAge: TimeInterval, now: Date = Date()) {
        let balancesByID = Dictionary(balances.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let pricesByID = Dictionary(prices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var seen = Set<String>()
        for query in queries where !query.chain.isTestnet {
            let address = query.chain.family == .litecoin ? ((try? Litecoin.addressInfo(query.account.networkAddress).canonicalAddress) ?? query.account.networkAddress) : (query.chain.isEVM ? query.account.networkAddress.lowercased() : query.account.networkAddress)
            let identity = query.walletID.uuidString + ":" + String(query.chain.id) + ":" + address + ":" + (query.token?.id ?? "native")
            guard seen.insert(identity).inserted else { continue }
            guard let snapshot = balancesByID[query.id], snapshot.matches(query), let balance = snapshot.balance else { unknownBalances += 1; continue }
            knownBalances += 1
            let oldBalance = snapshot.error != nil || now.timeIntervalSince(snapshot.updatedAt ?? .distantPast) > balanceMaxAge
            if oldBalance { historicalBalances += 1 }
            guard balance > 0 else { continue }
            guard let key = MarketPriceCatalog.key(chain: query.chain, token: query.token), let record = pricesByID[key], let quote = record.quote,
                  quote.matches(query), let units = quote.units, let amount = USDValue.holding(balance: balance, decimals: query.decimals, price: units) else { unpricedHoldings += 1; continue }
            total += amount; pricedHoldings += 1
            if record.error != nil || !quote.isFresh(at: now) || oldBalance { historicalHoldings += 1 }
        }
    }
}
