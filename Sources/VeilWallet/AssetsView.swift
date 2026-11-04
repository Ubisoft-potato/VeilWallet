import SwiftUI
import WalletCore
import BigInt

struct AssetsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    @ViewState private var currentNetworkOnly = false
    @ViewState private var hideZero = true
    @ViewState private var failedOnly = false
    init(showZeroBalances: Bool = false) { _hideZero = ViewState(initialValue: !showZeroBalances) }
    private var queries: [AssetQuery] { model.assetQueries.filter { !currentNetworkOnly || $0.chain.id == model.chainID } }
    private var funded: [AssetQuery] { queries.filter { (model.snapshot($0)?.balance ?? 0) > 0 } }
    private var visible: [AssetQuery] {
        queries.filter { query in
            (!failedOnly || model.snapshot(query)?.error != nil) && (!hideZero || (model.snapshot(query)?.balance ?? 0) > 0) && (search.isEmpty || [query.symbol, query.chain.name, query.account.networkAddress, query.token?.contract ?? "", query.token.flatMap { TokenCatalog.preset(for: $0)?.name } ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            let a = (model.snapshot(lhs)?.balance ?? 0) > 0, b = (model.snapshot(rhs)?.balance ?? 0) > 0
            return a != b ? a : false
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in content(now: context.date) }
    }
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                SectionTitle(eyebrow: L("section.assets.eyebrow"), title: L("navigation.assets"), subtitle: L("message.view_assets_and_receiving_addresses_across_networks_chain_queries_use"))
                Spacer()
                if model.wallet != nil { Pill(text: model.wallet?.canSign == true ? L("message.self_custody") : L("message.watch_only_wallet")) }
            }
            if let wallet = model.wallet, let account = model.account {
                valuationCard(now: now)
                balanceCard(wallet, account: account, now: now)
                if model.chain.family == .monero { MoneroStatusView() }
                if model.availableAccounts.count > 1 {
                    Picker(L("message.current_account_address_type"), selection: $model.profileID) { ForEach(model.availableAccounts) { item in Text(item.profile?.name ?? item.profileID).tag(item.profileID) } }.disabled(model.busy).onChange(of: model.profileID) { _, _ in model.selectionChanged() }
                }
                if !account.isBound { Text(L("message.this_network_requires_a_linked_on_chain_account_configure_it")).font(.system(size: 12)).foregroundStyle(.orange) }
                if let warning = model.chain.feeNotice { Text(warning).font(.system(size: 11)).foregroundStyle(.orange) }
                HStack {
                    Picker(L("message.network_scope"), selection: $currentNetworkOnly) { Text(L("message.all_wallet_networks")).tag(false); Text(L("message.current_network")).tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    Spacer()
                    Button { Task { await model.refreshMarketPrices() } } label: { Label(model.fetchingPrices ? L("message.updating_prices") : L("message.refresh_prices"), systemImage: "dollarsign.circle") }.disabled(!model.ready || model.fetchingPrices || !model.preferences.fetchUSDPrices)
                    Button { Task { await model.refreshPortfolio() } } label: { Label(model.discovering ? L("message.updating_2336147a") : L("message.refresh_assets"), systemImage: "arrow.clockwise") }.disabled(!model.ready || model.discovering)
                    Button(L("message.manage_tokens")) { model.sheet = .token }.disabled((!model.chain.isEVM && model.chain.family != .tron) || model.busy)
                }
                HStack {
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(L("message.search_assets_networks_contracts_or_addresses"), text: $search).textFieldStyle(.plain) }.padding(11).background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 10))
                    Toggle(L("message.with_balance_only"), isOn: $hideZero).toggleStyle(.checkbox).fixedSize()
                }
                if model.discovering {
                    VStack(alignment: .leading, spacing: 7) { ProgressView(value: Double(model.discoveryCompleted), total: Double(max(1, model.discoveryTotal))); Text(L("message.querying_0_1_through_tor_balances_update_individually", model.discoveryCompleted, model.discoveryTotal)).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                let failed = queries.filter { model.snapshot($0)?.error != nil }.count
                if failed > 0 {
                    HStack { Label(L("message.0_queries_failed_their_balances_are_unknown_not_zero", failed), systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange); Spacer(); Button(failedOnly ? L("message.show_all") : L("message.show_failed_queries")) { failedOnly.toggle(); if failedOnly { hideZero = false; search = "" } } }
                }
                Panel(padding: 0) {
                    LazyVStack(spacing: 0) {
                        HStack { Text(L("message.asset_network_wallet_address")); Spacer(); Text(L("message.unit_price_usd")).frame(width: 120, alignment: .trailing); Text(L("message.balance_value_usd")).frame(width: 165, alignment: .trailing); Text("").frame(width: 30) }.font(.system(size: 11)).foregroundStyle(.secondary).padding(20)
                        Divider()
                        if visible.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: model.discovering ? "network" : "tray").font(.system(size: 30)).foregroundStyle(Color.veilAccent)
                                Text(model.discovering ? L("message.discovering_assets") : L("message.no_known_balances_match_this_filter")).font(.system(size: 17, weight: .medium))
                                Text(L("message.an_unqueried_or_failed_balance_is_not_zero_browse_all")).font(.system(size: 12)).foregroundStyle(.secondary)
                                Button(L("message.browse_all_assets")) { hideZero = false; failedOnly = false; search = "" }
                            }.padding(32)
                        }
                        ForEach(visible) { query in portfolioRow(query, now: now); Divider().padding(.leading, 74) }
                    }
                }
                Text(L("message.usd_prices_come_from_defillama_through_tor_every_5_minutes")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Panel { VStack(alignment: .leading, spacing: 18) { Image(systemName: "wallet.bifold").font(.system(size: 38)).foregroundStyle(Color.veilAccent); Text(L("message.add_your_first_wallet")).font(.system(size: 24, weight: .medium)); Text(L("message.create_a_wallet_import_a_recovery_phrase_or_private_key")).foregroundStyle(.secondary); Button(L("message.add_wallet")) { model.sheet = .addWallet }.buttonStyle(PrimaryButton()) }.padding(.vertical, 30) }
            }
        }
    }
    private func valuationCard(now: Date) -> some View {
        let valuation = model.portfolioUSD(queries, now: now)
        return Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(currentNetworkOnly ? L("message.current_network_value_usd") : L("message.wallet_value_usd"), systemImage: "dollarsign.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.fetchingPrices ? L("message.updating_prices_bb365b6c") : L("message.defillama_via_tor")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(valuation.displayTotal).font(.system(size: 38, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.55).textSelection(.enabled).contentTransition(.numericText())
                Text(L("message.0_assets_with_balance_1_addresses_2_3_queried", funded.count, Set(funded.map { String($0.chain.id) + ":" + $0.account.networkAddress }).count, queries.filter { model.snapshot($0)?.updatedAt != nil }.count, queries.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(L("message.valued_holdings_0_unpriced_1_unknown_balances_2", valuation.pricedHoldings, valuation.unpricedHoldings, valuation.unknownBalances)).font(.system(size: 11)).foregroundStyle(.secondary)
                if valuation.historicalHoldings > 0 || valuation.historicalBalances > 0 { Text(L("message.historical_valuations_0_historical_balances_1_check_each_asset_s", valuation.historicalHoldings, valuation.historicalBalances)).font(.system(size: 11)).foregroundStyle(.orange) }
                if valuation.unpricedHoldings > 0 || valuation.unknownBalances > 0 { Text(L("message.this_is_a_partial_valuation_of_known_assets_excluded_holdings")).font(.system(size: 11)).foregroundStyle(.secondary) }
                if !model.preferences.fetchUSDPrices { Text(L("message.price_fetching_is_off_showing_the_local_cache")).font(.system(size: 11)).foregroundStyle(.orange) }
                if let error = model.priceRefreshError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            }
        }
    }
    private func portfolioRow(_ query: AssetQuery, now: Date) -> some View {
        let snapshot = model.snapshot(query)
        let market = model.marketSnapshot(query)
        return HStack(alignment: .center, spacing: 15) {
            AssetLogo(chain: query.chain, token: query.token, size: 40, nativeAsset: query.token == nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) { Text(query.symbol).font(.system(size: 15, weight: .semibold)); Text(query.chain.name).font(.system(size: 10)).foregroundStyle(.secondary); if let token = query.token, let preset = TokenCatalog.preset(for: token), !preset.provenance.isEmpty { Text(LK(preset.provenance)).font(.system(size: 9)).foregroundStyle(Color.veilAccent) } }
                HStack(spacing: 8) { Text(query.account.networkAddress).font(.system(size: 10, design: .monospaced)).lineLimit(1).textSelection(.enabled); IconButton(symbol: "doc.on.doc", title: L("message.copy_receiving_address")) { model.copyAddress(query.account.networkAddress) } }.foregroundStyle(.secondary)
                if let token = query.token { Text(L("message.contract") + token.contract).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 6) {
                Text(market?.quote?.units.map { USDValue.formatted($0, unitPrice: true) } ?? "—").font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
                Text(model.priceStatus(query, now: now)).font(.system(size: 9)).foregroundStyle(market?.quote?.isFresh(at: now) == true && market?.error == nil ? Color.secondary : .orange).lineLimit(2)
            }.frame(width: 120, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 6) {
                Text(snapshot?.balance.map { Ethereum.formatUnits($0, decimals: query.decimals, precision: query.decimals) } ?? "—").font(.system(size: 16, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.65).textSelection(.enabled)
                Text(model.assetUSDText(query)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65).textSelection(.enabled)
                if model.checkingAssets.contains(query.id) { Text(L("message.updating")).font(.system(size: 10)).foregroundStyle(Color.veilAccent) }
                else if let error = snapshot?.error { Text(snapshot?.balance == nil ? L("message.query_failed_retry_available") : L("message.previous_balance_update_failed")).font(.system(size: 10)).foregroundStyle(.orange).help(LS(error)) }
                else if let date = snapshot?.updatedAt { Text(walletDate(date, date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                else { Text(query.automatic ? L("message.not_queried") : L("message.local_scan_manual_query_required")).font(.system(size: 10)).foregroundStyle(.secondary) }
            }.frame(width: 165, alignment: .trailing)
            Menu { Button(L("message.view_this_network")) { model.openAsset(query) }; Button(L("message.receive_show_qr_code")) { model.openAsset(query, action: .receive) }; Button(L("message.send")) { model.openAsset(query, action: .send) }.disabled(model.wallet?.canSign != true || !query.chain.canTransfer || (!query.chain.isEVM && query.token != nil)) } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy).accessibilityLabel(L("message.more_asset_actions"))
        }.padding(20)
    }
    private func balanceCard(_ wallet: WalletSummary, account: WalletAccount, now: Date) -> some View {
        let query = AssetQuery(walletID: wallet.id, chain: model.chain, account: account)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) { AssetLogo(chain: model.chain, size: 23, nativeAsset: true); Text(L("message.0_current_account_s_native_asset", model.chain.name)).font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Image(systemName: "shield.checkered").foregroundStyle(Color.veilAccent) }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.balances["native"].map { Ethereum.formatUnits($0, decimals: model.chain.decimals, precision: model.chain.decimals) } ?? "—").font(.system(size: 34, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65).contentTransition(.numericText())
                Text(model.chain.symbol).font(.system(size: 19)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("≈ " + model.assetUSDText(query) + " USD").font(.system(size: 16, weight: .medium, design: .rounded))
                if let units = model.marketSnapshot(query)?.quote?.units { Text(L("message.unit_price") + USDValue.formatted(units, unitPrice: true)).font(.system(size: 12)) }
                Text(model.priceStatus(query, now: now)).font(.system(size: 10))
            }.foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(account.networkAddress).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                IconButton(symbol: "doc.on.doc", title: L("message.copy_address_clipboard_clears_after_30_seconds")) { model.copyAddress(account.networkAddress) }
            }.foregroundStyle(.secondary)
            if let snapshot = model.snapshot(AssetQuery(walletID: wallet.id, chain: model.chain, account: account)), let date = snapshot.updatedAt {
                Text((snapshot.error == nil ? L("message.last_queried") : L("message.update_failed_previous_balance")) + walletDate(date, date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(snapshot.error == nil ? Color.secondary : .orange)
            }
            ActionFlow {
                Button { model.sheet = .send } label: { Label(L("message.send"), systemImage: "arrow.up.right") }.buttonStyle(PrimaryButton()).disabled(!wallet.canSign || !model.ready || !model.canSendCurrentAccount || !account.isBound)
                Button { model.sheet = .receive } label: { Label(L("message.receive"), systemImage: "qrcode") }.disabled(!account.isBound)
                if model.chain.isEVM {
                    Button(L("message.contract_call")) { model.sheet = .contract }.disabled(!model.ready)
                    Button(L("message.dex_swap")) { model.sheet = .swap }.disabled(!model.ready || !wallet.canSign || DexCatalog.on(model.chainID).isEmpty)
                }
                if model.chain.family == .tron { Button(L("message.dex_swap")) { model.sheet = .swap }.disabled(!model.ready || !wallet.canSign) }
                if !BridgeCatalog.on(model.chainID).isEmpty { Button(L("message.bridge")) { model.sheet = .bridge }.disabled(!model.ready) }
                if !PrivacyPoolCatalog.on(model.chainID).isEmpty || model.chain.family == .tron { Button(L("message.privacy_pools")) { model.sheet = .privacyPool } }
            }.padding(.top, 6)
            Text(account.path ?? (wallet.canSign ? L("message.imported_private_key") : L("message.watch_only_address_cannot_sign"))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(20).background(LinearGradient(colors: [Color.veilAccent.opacity(0.12), Color.veilPanel, Color.veilPanel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.veilAccent.opacity(0.17)).allowsHitTesting(false))
    }
}
