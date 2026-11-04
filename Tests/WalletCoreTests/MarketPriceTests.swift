import Foundation
import Testing
import BigInt
@testable import WalletCore

private actor MarketFixture: PrivateRequesting {
    var requests: [PrivateRequest] = []
    var fail = false
    init(fail: Bool = false) { self.fail = fail }
    func execute(_ request: PrivateRequest) async throws -> Data {
        requests.append(request)
        if fail { throw WalletError.transport(28) }
        return Data("{\"coins\":{}}".utf8)
    }
}
struct MarketPriceTests {
    private let now = Date(timeIntervalSince1970: 1_793_721_000)
    private let sender = "0x000000000000000000000000000000000000dEaD"
    private func query(chainID: UInt64 = 56, symbol: String? = "USDT", wallet: UUID = UUID()) -> AssetQuery {
        let chain = Chain.defaults.first { $0.id == chainID }!
        let token = symbol.flatMap { symbol in TokenCatalog.all.first { $0.chainID == chainID && $0.symbol == symbol }?.token }
        return .init(walletID: wallet, chain: chain, account: WalletAccount(profileID: "evm", address: sender), token: token)
    }
    private func price(_ query: AssetQuery, value: String = "0.9989322407052479", age: TimeInterval = 0, decimals: Int? = 18) throws -> MarketPriceSnapshot {
        let key = MarketPriceCatalog.key(chain: query.chain, token: query.token)!
        let quote = MarketPrice(key: key, units: try USDValue.priceUnits(Decimal(string: value)!), sourceTimestamp: now.addingTimeInterval(-age), fetchedAt: now, tokenDecimals: decimals)
        return .init(key: key, quote: quote, error: nil, now: now)
    }
    @Test func priceIdentityUsesGasAssetAndContractsNeverTicker() throws {
        #expect(MarketPriceCatalog.networks.count == 119)
        for entry in MarketPriceCatalog.networks {
            let chain = try #require(Chain.defaults.first { $0.id == entry.chainID })
            #expect(entry.family == chain.family && entry.nativeDecimals == chain.decimals && entry.nativeSymbol == chain.symbol)
        }
        let eth = query(chainID: 1, symbol: nil), arb = query(chainID: 42161, symbol: nil), op = query(chainID: 10, symbol: nil)
        for q in [eth, arb, op] { #expect(MarketPriceCatalog.key(chain: q.chain) == "coingecko:ethereum") }
        let bsc = query(), ethUSDT = query(chainID: 1)
        #expect(MarketPriceCatalog.key(chain: bsc.chain, token: bsc.token) == "bsc:0x55d398326f99059ff775485246999027b3197955")
        #expect(MarketPriceCatalog.key(chain: ethUSDT.chain, token: ethUSDT.token) == "ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7")
        let spoof = try Token(chainID: 56, contract: "0x1111111111111111111111111111111111111111", symbol: "USDT", decimals: 18)
        #expect(MarketPriceCatalog.key(chain: bsc.chain, token: spoof) != MarketPriceCatalog.key(chain: bsc.chain, token: bsc.token))
        #expect(MarketPriceCatalog.key(chain: bsc.chain, token: ethUSDT.token) == nil)
        var testnet = bsc.chain; testnet.isTestnet = true
        #expect(MarketPriceCatalog.key(chain: testnet) == nil)
        #expect(MarketPriceCatalog.key(chain: Chain(id: 999999, name: "custom", symbol: "ETH", rpcURL: "https://example.invalid")) == nil)
        let tron = Chain.defaults.first { $0.family == .tron }!, token = TokenCatalog.all.first { $0.chainID == tron.id && $0.symbol == "USDT" }!.token
        #expect(MarketPriceCatalog.key(chain: tron, token: token) == "tron:" + token.contract)
        for family: NetworkFamily in [.bitcoin, .litecoin, .monero, .solana, .tron] { #expect(MarketPriceCatalog.key(chain: Chain.defaults.first { $0.family == family }!) != nil) }
    }
    @Test func decimalConversionAndUSDHoldingsPreservePrecision() throws {
        let stable = try USDValue.priceUnits(Decimal(string: "0.9989322407052479")!)
        #expect(stable == BigUInt("998932240705247900"))
        #expect(USDValue.holding(balance: BigUInt(100) * BigUInt(10).power(18), decimals: 18, price: stable) == stable * 100)
        #expect(USDValue.holding(balance: 100_000_000, decimals: 6, price: stable) == stable * 100)
        #expect(USDValue.formatted(stable * 100) == "$99.89")
        #expect(USDValue.formatted(try USDValue.priceUnits(Decimal(string: "123456789.125")!)) == "$123,456,789.13")
        #expect(USDValue.formatted(try USDValue.priceUnits(Decimal(string: "0.000000000123")!), unitPrice: true) == "$0.000000000123")
        #expect(USDValue.formatted(1) == "<$0.01")
        #expect(USDValue.formatted(0, positiveHolding: true) == "<$0.01")
        #expect(USDValue.formatted(0) == "$0.00")
        #expect(USDValue.holding(balance: BigUInt(10).power(30), decimals: 18, price: stable) == stable * BigUInt(10).power(12))
        #expect(USDValue.holding(balance: 1, decimals: -1, price: stable) == nil)
        for invalid in [Decimal.zero, Decimal(-1), Decimal.nan, Decimal(string: "0.0000000000000000001")!, Decimal(string: "1000000000000001")!] {
            do { _ = try USDValue.priceUnits(invalid); Issue.record("Invalid price accepted") } catch {}
        }
    }
    @Test func responseValidationIsPerAssetAndRetainsExactJSONDecimal() throws {
        let keys = ["bsc:good", "bsc:missing", "bsc:low", "bsc:future", "bsc:old", "bsc:negative", "bsc:malformed", "bsc:noDecimals", "coingecko:bitcoin"]
        let json = """
        {"coins":{
        "bsc:good":{"price":0.9989322407052479,"timestamp":1793721000,"confidence":0.99,"decimals":18},
        "bsc:low":{"price":1,"timestamp":1793721000,"confidence":0.1,"decimals":18},
        "bsc:future":{"price":1,"timestamp":1793722000,"confidence":1,"decimals":18},
        "bsc:old":{"price":1,"timestamp":1793000000,"confidence":1,"decimals":18},
        "bsc:negative":{"price":-1,"timestamp":1793721000,"confidence":1,"decimals":18},
        "bsc:malformed":"not an object", "bsc:noDecimals":{"price":1,"timestamp":1793721000,"confidence":1},
        "coingecko:bitcoin":{"price":70000.12345678,"timestamp":1793721000,"confidence":0.999},
        "coingecko:unrequested":{"price":100,"timestamp":1793721000,"confidence":1}
        }}
        """
        let records = try MarketPriceClient.decode(Data(json.utf8), requested: keys, now: now)
        #expect(records.count == keys.count); #expect(records.filter { $0.quote != nil }.count == 2)
        #expect(records.first?.quote?.units == BigUInt("998932240705247900"))
        #expect(records.last?.quote?.tokenDecimals == nil)
        #expect(records.last?.quote?.isFresh(at: now) == true)
        #expect(records.last?.quote?.isFresh(at: now.addingTimeInterval(901)) == false)
    }
    @Test func partialTotalsKeepUnknownAndStaleSeparateAndDeduplicateAddresses() throws {
        let wallet = UUID(), bsc = query(wallet: wallet), eth = query(chainID: 1, wallet: wallet), missing = query(chainID: 8453, symbol: nil, wallet: wallet)
        var balance = AssetBalanceSnapshot(query: bsc, balance: BigUInt(100) * BigUInt(10).power(18)); balance.updatedAt = now
        let records = [balance, AssetBalanceSnapshot(query: eth, balance: 1_000_000)]
        let p = try price(bsc)
        let totals = PortfolioUSD(queries: [bsc,bsc,eth,missing], balances: records, prices: [p], balanceMaxAge: 300, now: now)
        #expect(totals.pricedHoldings == 1 && totals.unpricedHoldings == 1 && totals.unknownBalances == 1)
        #expect(totals.displayTotal == "$99.89"); #expect(totals.historicalHoldings == 0)
        let failed = MarketPriceSnapshot(key: p.id, quote: nil, error: "offline", previous: p, now: now.addingTimeInterval(300))
        #expect(failed.quote?.sourceTimestamp == p.quote?.sourceTimestamp)
        let cached = PortfolioUSD(queries: [bsc], balances: [balance], prices: [failed], balanceMaxAge: 300, now: now)
        #expect(cached.displayTotal == "$99.89" && cached.historicalHoldings == 1)
        let old = PortfolioUSD(queries: [bsc], balances: [balance], prices: [try price(bsc, age: 901)], balanceMaxAge: 300, now: now)
        #expect(old.historicalHoldings == 1)
        let mismatch = PortfolioUSD(queries: [bsc], balances: [balance], prices: [try price(bsc, decimals: 6)], balanceMaxAge: 300, now: now)
        #expect(mismatch.displayTotal == "—" && mismatch.unpricedHoldings == 1)
        let unknown = PortfolioUSD(queries: [bsc], balances: [], prices: [p], balanceMaxAge: 300, now: now)
        #expect(unknown.displayTotal == "—")
        let zero = PortfolioUSD(queries: [bsc], balances: [AssetBalanceSnapshot(query: bsc, balance: 0)], prices: [], balanceMaxAge: 300, now: now)
        #expect(zero.displayTotal == "$0.00")
        var staleZero = AssetBalanceSnapshot(query: bsc, balance: 0); staleZero.error = "timeout"
        #expect(PortfolioUSD(queries: [bsc], balances: [staleZero], prices: [], balanceMaxAge: 300, now: now).historicalBalances == 1)
        let test = query(chainID: 11155111, symbol: nil, wallet: wallet)
        let excluded = PortfolioUSD(queries: [test], balances: [AssetBalanceSnapshot(query: test, balance: BigUInt(10).power(30))], prices: [p], balanceMaxAge: 300, now: now)
        #expect(excluded.pricedHoldings == 0 && excluded.total == 0 && excluded.knownBalances == 0)
    }
    @Test func priceRequestsContainOnlyCatalogIdentifiersAndStayBounded() async throws {
        let fixture = MarketFixture(), keys = MarketPriceCatalog.requestKeys()
        #expect(keys.count > 100); #expect(keys == Array(Set(keys)).sorted())
        let values = try await MarketPriceClient(transport: fixture, isolation: "market-test").fetch(keys: keys + keys, now: now)
        #expect(values.count == keys.count)
        for request in await fixture.requests {
            #expect(request.url.host == "coins.llama.fi" && request.url.scheme == "https")
            #expect(request.body == nil && request.url.query == nil)
            #expect(!request.url.absoluteString.contains(sender))
            #expect(request.url.lastPathComponent.split(separator: ",").count <= 25)
            #expect(request.isolation == "market-test")
        }
        for bad in ["bsc:0xabc/secret", "coingecko:eth?address=x", "x:y,z:t", "x:", ":x"] {
            do { _ = try await MarketPriceClient(transport: fixture, isolation: "test").fetch(keys: [bad]); Issue.record("Path injection accepted") } catch {}
        }
        let outage = try await MarketPriceClient(transport: MarketFixture(fail: true), isolation: "test").fetch(keys: [keys[0]], now: now)
        #expect(outage[0].quote == nil && outage[0].error != nil)
        let blocked = try await MarketPriceClient(transport: TorTransport(gate: NetworkGate()), isolation: "closed-market-test").fetch(keys: ["coingecko:bitcoin"], now: now)
        #expect(blocked[0].quote == nil && blocked[0].error != nil)
    }
    @Test func oldPreferencesMigrateAndPricesRemainInEncryptedLocalStorage() async throws {
        let old = Data("{\"autoLockMinutes\":30,\"autoRefreshAssets\":true,\"refreshMinutes\":5,\"scanScope\":\"common\"}".utf8)
        var preferences = try JSONDecoder().decode(WalletPreferences.self, from: old)
        #expect(preferences.fetchUSDPrices)
        preferences.fetchUSDPrices = false
        #expect(try JSONDecoder().decode(WalletPreferences.self, from: JSONEncoder().encode(preferences)).fetchUSDPrices == false)
        let oldState = try JSONDecoder().decode(LocalStore.State.self, from: Data("{\"chains\":[],\"tokens\":[],\"activities\":[]}".utf8))
        #expect(oldState.marketPrices == nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("local.sealed"), store = try LocalStore(url: url, testingKey: Data(repeating: 2, count: 32))
        var state = LocalStore.State(); state.marketPrices = [try price(query())]; state.preferences = preferences
        try await store.save(state)
        let loaded = try await store.load()
        #expect(loaded.marketPrices?.first?.quote?.usdUnits == state.marketPrices?.first?.quote?.usdUnits)
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == nil)
    }
}
