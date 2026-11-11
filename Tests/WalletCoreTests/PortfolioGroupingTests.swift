import Foundation
import Testing
import BigInt
@testable import WalletCore

struct PortfolioGroupingTests {
    private let walletID = UUID()
    private let account = WalletAccount(profileID: "evm", address: "0x000000000000000000000000000000000000dEaD")
    private func native(_ id: UInt64, wallet: UUID? = nil) throws -> AssetQuery {
        AssetQuery(walletID: wallet ?? walletID, chain: try #require(Chain.defaults.first { $0.id == id }), account: account)
    }
    private func token(_ id: UInt64, _ symbol: String) throws -> AssetQuery {
        let preset = try #require(TokenCatalog.all.first { $0.chainID == id && $0.symbol == symbol })
        return AssetQuery(walletID: walletID, chain: try #require(Chain.defaults.first { $0.id == id }), account: account, token: preset.token)
    }
    private func price(_ query: AssetQuery, _ value: String, now: Date, age: TimeInterval = 0) throws -> MarketPriceSnapshot {
        let key = try #require(MarketPriceCatalog.key(chain: query.chain, token: query.token))
        return MarketPriceSnapshot(key: key, quote: MarketPrice(key: key, units: try USDValue.priceUnits(try #require(Decimal(string: value))), sourceTimestamp: now.addingTimeInterval(-age), fetchedAt: now, tokenDecimals: query.token?.decimals), error: nil, now: now)
    }
    @Test func crossChainAmountsNormalizeDecimalsAndUseEachNetworksPrice() throws {
        let eth = try token(1, "USDT"), bsc = try token(56, "USDT"), now = Date()
        let group = try #require(PortfolioAssetGroup.groups([eth, bsc]).first)
        #expect(group.holdings.count == 2); #expect(group.networks.count == 2)
        let balances = [AssetBalanceSnapshot(query: eth, balance: try Ethereum.parseUnits("1.234567", decimals: 6)), AssetBalanceSnapshot(query: bsc, balance: try Ethereum.parseUnits("2.000000000000000001", decimals: 18))]
        let summary = PortfolioAssetGroupSummary(group: group, balances: balances, prices: try [price(eth, "0.998", now: now), price(bsc, "1.001", now: now)], balanceMaxAge: 300, now: now)
        #expect(summary.decimals == 18); #expect(summary.displayBalance == "3.234567000000000001")
        #expect(summary.valuation.total == (balances[0].balance! * (try USDValue.priceUnits(Decimal(string: "0.998")!)) / BigUInt(10).power(6)) + (balances[1].balance! * (try USDValue.priceUnits(Decimal(string: "1.001")!)) / BigUInt(10).power(18)))
        #expect(summary.minimumPrice == (try USDValue.priceUnits(Decimal(string: "0.998")!)))
        #expect(summary.maximumPrice == (try USDValue.priceUnits(Decimal(string: "1.001")!)))
        #expect(summary.unknownBalances == 0); #expect(summary.missingPrices == 0)
    }
    @Test func reviewedIdentitiesKeepVersionsSpoofsAndTestnetsSeparate() throws {
        let eth = try native(1), base = try native(8453), test = try native(11155111)
        let usdc = try token(1, "USDC"), bscUSDC = try token(56, "USDC"), bridged = try token(42161, "USDC.e"), usdt0 = try token(42161, "USDT0"), usdt = try token(1, "USDT"), wrapped = try token(1, "WETH")
        let fakeToken = try Token(chainID: 1, contract: "0x000000000000000000000000000000000000bEEF", symbol: "USDC", decimals: 6)
        let fake = AssetQuery(walletID: walletID, chain: eth.chain, account: account, token: fakeToken)
        let changedMetadata = AssetQuery(walletID: walletID, chain: usdc.chain, account: account, token: try Token(chainID: 1, contract: usdc.token!.contract, symbol: "USDC", decimals: 18))
        let custom = AssetQuery(walletID: walletID, chain: Chain(id: 123456789, name: "Fixture", symbol: "ETH", rpcURL: "https://example.invalid"), account: account)
        let groups = PortfolioAssetGroup.groups([eth, base, test, usdc, bscUSDC, bridged, usdt0, usdt, wrapped, fake, changedMetadata, custom])
        #expect(groups.count == 10)
        #expect(groups[0].holdings.map(\.id) == [eth.id, base.id]); #expect(groups[2].holdings.count == 2)
        #expect(groups.first { $0.holdings.contains { $0.id == wrapped.id } }?.holdings.count == 1)
        #expect(PortfolioAssetGroup.groups([try native(1), try native(1, wallet: UUID())]).count == 2)
        var impostor = base.chain; impostor.symbol = "USDC"
        #expect(PortfolioAssetGroup.groups([usdc, AssetQuery(walletID: walletID, chain: impostor, account: account)]).count == 2)
        let noble = try #require(Chain.defaults.first { $0.family == .cosmos && $0.symbol == "USDC" })
        #expect(PortfolioAssetGroup.groups([usdc, AssetQuery(walletID: walletID, chain: noble, account: account)]).count == 1)
    }
    @Test func filtersAndRefreshesRetainGroupIdentityWithoutDoubleCountingAddresses() throws {
        let eth = try token(1, "USDT"), bsc = try token(56, "USDT"), tron = try token(TronAddress.chainID, "USDT")
        let group = try #require(PortfolioAssetGroup.groups([eth, bsc, tron]).first)
        #expect(PortfolioAssetGroup.groups([tron, bsc]).first?.id == group.id)
        #expect(PortfolioAssetGroup.groups([bsc]).first?.id == group.id)
        let alias = AssetQuery(walletID: walletID, chain: eth.chain, account: WalletAccount(profileID: "alias", address: account.address.lowercased()), token: eth.token)
        #expect(PortfolioAssetGroup.groups([eth, alias, eth, bsc]).first?.holdings.count == 2)
        let usd = try token(1, "USDC")
        #expect(PortfolioAssetGroup.groups([eth, usd, bsc]).map(\.symbol) == ["USDT", "USDC"])
    }
    @Test func unknownFailedAndHistoricalHoldingsNeverBecomeZeroOrFresh() throws {
        let eth = try token(1, "USDT"), bsc = try token(56, "USDT"), now = Date()
        let group = try #require(PortfolioAssetGroup.groups([eth, bsc]).first)
        let unknown = PortfolioAssetGroupSummary(group: group, balances: [], prices: [], balanceMaxAge: 300, now: now)
        #expect(unknown.balance == nil); #expect(unknown.displayBalance == "—"); #expect(unknown.unknownBalances == 2); #expect(unknown.valuation.displayTotal == "—")
        let previous = AssetBalanceSnapshot(query: eth, balance: 1_000_000)
        let failed = AssetBalanceSnapshot(query: eth, balance: nil, error: "fixture failure", previous: previous)
        let partial = PortfolioAssetGroupSummary(group: group, balances: [failed], prices: try [price(eth, "1", now: now, age: 3600)], balanceMaxAge: 300, now: now)
        #expect(partial.displayBalance == "1"); #expect(partial.unknownBalances == 1); #expect(partial.historicalBalances == 1)
        #expect(partial.valuation.unknownBalances == 1); #expect(partial.valuation.historicalHoldings == 1); #expect(partial.historicalPrices); #expect(partial.missingPrices == 1)
        var changed = eth.chain; changed.rpcURL = "https://different.example.invalid"
        let changedGroup = try #require(PortfolioAssetGroup.groups([AssetQuery(walletID: walletID, chain: changed, account: account, token: eth.token)]).first)
        #expect(PortfolioAssetGroupSummary(group: changedGroup, balances: [previous], prices: [], balanceMaxAge: 300, now: now).balance == nil)
    }
    @Test func aggregationRetainsTinyUnitsAndTestnetHasNoUSDValue() throws {
        let eth = try native(1)
        let other = AssetQuery(walletID: walletID, chain: eth.chain, account: WalletAccount(profileID: "second", address: "0x000000000000000000000000000000000000bEEF"))
        let group = try #require(PortfolioAssetGroup.groups([eth, other]).first)
        let amount = BigUInt(2).power(256) - 1
        let summary = PortfolioAssetGroupSummary(group: group, balances: [AssetBalanceSnapshot(query: eth, balance: amount), AssetBalanceSnapshot(query: other, balance: 1)], prices: [], balanceMaxAge: 300)
        #expect(summary.balance == BigUInt(2).power(256))
        let tiny = PortfolioAssetGroupSummary(group: group, balances: [AssetBalanceSnapshot(query: eth, balance: 1)], prices: [], balanceMaxAge: 300)
        #expect(tiny.displayBalance == "0.000000000000000001")
        let test = try native(11155111), testGroup = try #require(PortfolioAssetGroup.groups([test]).first)
        #expect(PortfolioAssetGroupSummary(group: testGroup, balances: [AssetBalanceSnapshot(query: test, balance: 1)], prices: [], balanceMaxAge: 300).valuation.displayTotal == "—")
    }
}
