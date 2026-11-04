import Foundation
import WalletCore
import BigInt

@MainActor extension AppModel {
    var marketRefreshKey: String {
        [String(networkSessionReady), String(busy), String(preferences.fetchUSDPrices), local.tokens.map(\.id).sorted().joined(separator: ",")].joined(separator: "|")
    }
    func marketSnapshot(_ query: AssetQuery) -> MarketPriceSnapshot? {
        guard let key = MarketPriceCatalog.key(chain: query.chain, token: query.token),
              let record = local.marketPrices?.first(where: { $0.id == key }), record.quote?.matches(query) == true else { return nil }
        return record
    }
    func assetUSD(_ query: AssetQuery) -> BigUInt? {
        guard let balance = snapshot(query)?.balance else { return nil }
        if balance == 0, !query.chain.isTestnet { return 0 }
        guard let units = marketSnapshot(query)?.quote?.units else { return nil }
        return USDValue.holding(balance: balance, decimals: query.decimals, price: units)
    }
    func portfolioUSD(_ queries: [AssetQuery], now: Date) -> PortfolioUSD {
        PortfolioUSD(queries: queries, balances: local.assetBalances ?? [], prices: local.marketPrices ?? [], balanceMaxAge: preferences.refreshInterval + 60, now: now)
    }
    func assetUSDText(_ query: AssetQuery) -> String {
        assetUSD(query).map { USDValue.formatted($0, positiveHolding: (snapshot(query)?.balance ?? 0) > 0) } ?? "—"
    }
    func priceStatus(_ query: AssetQuery, now: Date) -> String {
        if query.chain.isTestnet { return L("message.testnet_excluded_from_usd_value") }
        guard let key = MarketPriceCatalog.key(chain: query.chain, token: query.token) else { return L("message.no_price_mapping") }
        guard let record = local.marketPrices?.first(where: { $0.id == key }), let quote = record.quote else {
            return fetchingPrices ? L("message.updating_prices_bb365b6c") : (preferences.fetchUSDPrices ? L("message.usd_price_unavailable") : L("message.price_fetching_is_off"))
        }
        guard quote.matches(query) else { return L("message.price_decimals_do_not_match") }
        if !quote.isFresh(at: now) { return L("message.historical_price") + walletDate(quote.sourceTimestamp, date: .abbreviated, time: .shortened) }
        if record.error != nil { return L("message.previous_price_update_failed") }
        return L("message.price") + walletDate(quote.sourceTimestamp, date: .omitted, time: .shortened)
    }
    func runAutomaticMarketRefresh() async {
        guard preferences.fetchUSDPrices else { return }
        while !Task.isCancelled, networkSessionReady, preferences.fetchUSDPrices {
            while fetchingPrices, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            if !busy { await refreshMarketPrices(force: false) }
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
        }
    }
    func refreshMarketPrices(force: Bool = true) async {
        guard networkSessionReady, !busy, !fetchingPrices, preferences.fetchUSDPrices else { return }
        let keys = MarketPriceCatalog.requestKeys(customTokens: local.tokens), operation = epoch, run = UUID()
        let existing = Dictionary((local.marketPrices ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // One catalog batch per interval, never a request shaped by holdings.
        guard force || keys.contains(where: { key in existing[key].map { Date().timeIntervalSince($0.attemptedAt) >= 300 } ?? true }) else { return }
        fetchingPrices = true; priceRun = run; priceRefreshError = nil
        defer { if priceRun == run { fetchingPrices = false; priceRun = nil } }
        do {
            let values = try await MarketPriceClient(transport: TorTransport(gate: gate), isolation: "market:" + run.uuidString).fetch(keys: keys)
            guard !Task.isCancelled, operation == epoch, networkSessionReady, !busy, preferences.fetchUSDPrices else { return }
            local.marketPrices = values.map { .init(key: $0.id, quote: $0.quote, error: $0.error, previous: existing[$0.id], now: $0.attemptedAt) }
            if values.allSatisfy({ $0.quote == nil }), !values.isEmpty { priceRefreshError = L("message.the_price_service_is_unavailable_previous_prices_were_retained") }
            try await saveLocal()
        } catch is CancellationError {} catch {
            if operation == epoch, unlocked { priceRefreshError = L("message.price_refresh_did_not_finish_try_again_later") }
        }
    }
}
