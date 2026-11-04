import SwiftUI
import WalletCore

struct PrivacyView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionTitle(eyebrow: L("section.privacy.eyebrow"), title: L("message.keep_connections_private"), subtitle: L("message.privacy_depends_on_inspectable_behavior_and_boundaries_these_are_the"))
            Panel {
                HStack(spacing: 20) {
                    Image(systemName: "network.badge.shield.half.filled").font(.system(size: 42)).foregroundStyle(model.gate.isReady ? Color.veilGreen : .orange)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.tor.state.label).font(.system(size: 21, weight: .medium))
                        Text(L("message.app_bundled_tor_https_xmr_onion_node")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("message.reconnect_tor")) { model.restartTor() }.disabled(model.busy)
                }
                if case .starting(let progress) = model.tor.state { ProgressView(value: Double(progress), total: 100).padding(.top, 18) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                privacyCard(L("message.remote_dns_resolution"), icon: "globe", detail: L("message.socks5_passes_the_destination_domain_to_the_tor_exit_for"))
                privacyCard(L("message.fail_closed"), icon: "lock.shield", detail: L("message.there_is_no_direct_connection_fallback_tor_exit_wallet_lock"))
                privacyCard(L("message.no_app_analytics"), icon: "hand.raised", detail: L("message.no_tracking_sdks_ads_crash_uploads_remote_fonts_or_icons"))
                privacyCard(L("message.isolated_wallet_sessions"), icon: "square.stack.3d.up", detail: L("message.regular_rpc_is_isolated_by_session_wallet_and_chain_the"))
            }
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("message.on_chain_privacy_pools_and_bridges")).font(.system(size: 17, weight: .medium))
                    Text(L("message.eth_bsc_have_fixed_denomination_pools_and_independent_note_backups")).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button(L("message.open_notes_and_privacy_pools")) { model.sheet = .privacyPool }.disabled(PrivacyPoolCatalog.on(model.chainID).isEmpty && model.chain.family != .tron)
                        Button(L("message.open_bridges")) { model.sheet = .bridge }.disabled(!model.ready || BridgeCatalog.on(model.chainID).isEmpty)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Label(L("message.protection_boundaries"), systemImage: "info.circle").font(.system(size: 16, weight: .medium))
                    Text(L("message.tor_hides_your_source_ip_from_nodes_it_does_not"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6)
                    Text(L("message.switching_apps_keeps_the_wallet_unlocked_it_locks_after_0", model.preferences.autoLockMinutes))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6)
                }
            }
        }
    }
    private func privacyCard(_ title: String, icon: String, detail: String) -> some View {
        Panel(padding: 22) {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Image(systemName: icon).foregroundStyle(Color.veilAccent); Text(title).font(.system(size: 14, weight: .medium)) }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).frame(minHeight: 48, alignment: .top)
            }
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var rpc = ""
    @ViewState private var customName = ""
    @ViewState private var customID = ""
    @ViewState private var customSymbol = "ETH"
    @ViewState private var customURL = ""
    @ViewState private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionTitle(eyebrow: L("section.settings.eyebrow"), title: L("message.you_are_in_control"), subtitle: L("message.local_configuration_no_account_registration_or_settings_upload"))
            Panel { LanguagePreferenceView() }
            WalletExperienceSettings()
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("message.wallet_and_backup"), systemImage: "wallet.bifold").font(.system(size: 17, weight: .medium))
                    if let wallet = model.wallet {
                        Text("\(wallet.name) · \(model.address ?? wallet.address)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            if wallet.canSign { Button(L("message.verify_password_and_reveal_backup_9db30fb4")) { model.sheet = .backup } }
                            Button(L("message.manage_wallets_change_password")) { model.sheet = .manage }
                        }
                    }
                    Text(L("message.vault_aes_256_gcm_pbkdf2_hmac_sha256_with_600_000")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("message.advanced_network_settings"), systemImage: "slider.horizontal.3").font(.system(size: 17, weight: .medium))
                    Text(L("message.expand_as_needed_changes_stay_on_this_mac")).font(.system(size: 12)).foregroundStyle(.secondary)
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 14) {
                        Pill(text: model.chain.family == .monero ? "V3 ONION / TOR" : "HTTPS / TOR")
                        Text(model.chain.family == .monero ? L("message.xmr_accepts_complete_v3_onion_node_addresses_only_the_official") : L("message.public_nodes_see_queried_addresses_and_may_rate_limit_or")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                        HStack {
                            TextField(model.chain.family == .monero ? L("message.http_full_v3_address_onion_18081") : "https://rpc.example.com", text: $rpc).textFieldStyle(.roundedBorder)
                            Button(L("message.save_endpoint")) { saveRPC() }.disabled(model.busy)
                        }
                        }
                    } label: { Label(L("message.current_endpoint") + model.chain.name, systemImage: "network") }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            FieldLabel(title: L("message.name")) { TextField(L("message.custom_network"), text: $customName) }
                            FieldLabel(title: L("field.chain_id")) { TextField(L("message.decimal"), text: $customID) }
                            FieldLabel(title: L("message.native_symbol")) { TextField(L("placeholder.native_symbol"), text: $customSymbol) }
                        }
                        FieldLabel(title: L("field.https_rpc")) { TextField(L("placeholder.rpc"), text: $customURL) }
                        Button(L("message.add_network")) { addChain() }.disabled(model.busy)
                        }
                    } label: { Label(L("message.add_a_custom_evm_network"), systemImage: "plus.circle") }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 14) {
                        Text(L("message.use_bridges_when_direct_tor_connections_fail_enter_one_obfs4")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                        TextEditor(text: $model.bridges).font(.system(size: 11, design: .monospaced)).frame(height: 80).scrollContentBackground(.hidden)
                            .padding(8).background(Color.veilBackground, in: RoundedRectangle(cornerRadius: 8))
                        Button(L("message.reconnect_using_bridges")) { model.restartTor() }.disabled(model.busy)
                        }
                    } label: { Label(L("message.tor_bridges_obfs4"), systemImage: "point.3.connected.trianglepath.dotted") }
                }
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(Color.veilGreen) }
        }.onAppear { rpc = model.chain.rpcURL }.onChange(of: model.chainID) { _, _ in rpc = model.chain.rpcURL; message = nil }
    }
    private func saveRPC() {
        do {
            guard let url = URL(string: rpc) else { throw WalletError.invalid(L("message.invalid_url")) }
            if model.chain.family == .monero { _ = try MoneroNode.validate(rpc); model.monero.stop() }
            else { try PrivateRequest.validate(url) }
            guard let i = model.local.chains.firstIndex(where: { $0.id == model.chainID }) else { return }
            let old = model.local.chains[i].rpcURL; model.local.chains[i].rpcURL = rpc
            Task {
                do { try await model.saveLocal(); model.selectionChanged(); message = L("message.endpoint_saved_locally") }
                catch { model.local.chains[i].rpcURL = old; model.error = error.localizedDescription }
            }
        } catch { model.error = error.localizedDescription }
    }
    private func addChain() {
        do {
            guard let id = UInt64(customID), id > 0, id < 0x8000000000000000, !model.local.chains.contains(where: { $0.id == id }),
                  !customName.isEmpty, customName.count <= 40, !customSymbol.isEmpty, customSymbol.count <= 12,
                  let url = URL(string: customURL) else { throw WalletError.invalid(L("message.check_the_name_symbol_and_unique_valid_chain_id")) }
            try PrivateRequest.validate(url)
            model.local.chains.append(Chain(id: id, name: customName, symbol: customSymbol, rpcURL: customURL))
            Task {
                do { try await model.saveLocal(); model.chainID = id; message = L("message.network_added_the_first_query_will_verify_its_chain_id"); customName = ""; customID = ""; customURL = "" }
                catch { model.local.chains.removeAll { $0.id == id }; model.error = error.localizedDescription }
            }
        } catch { model.error = error.localizedDescription }
    }
}
struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionTitle(eyebrow: L("section.discover.eyebrow"), title: L("message.explore_web3"), subtitle: L("message.protocol_features_are_added_individually_after_their_privacy_requirements_are"))
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Pill(text: L("message.current_capabilities"), color: .orange)
                    Text(L("message.native_contracts_swaps_bridges_and_privacy_pools")).font(.system(size: 22, weight: .medium))
                    Text(L("message.native_support_for_common_evm_dex_protocols_and_tron_sun"))
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6)
                    HStack {
                        Button(L("message.contract_call")) { model.sheet = .contract }.disabled(!model.ready || !model.chain.isEVM)
                        Button(L("message.dex_swap")) { model.sheet = .swap }.disabled(!model.ready || (model.chain.family != .tron && DexCatalog.on(model.chainID).isEmpty) || model.wallet?.canSign != true)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                roadmap(L("message.more_bridges_and_market_wide_routing"), icon: "arrow.left.arrow.right", detail: L("message.allbridge_oft_and_stargate_v2_support_fixed_usdt_routes_more"))
                roadmap("NFT", icon: "square.grid.2x2", detail: L("message.erc_721_1155_assets_and_transfers_remote_metadata_and_media"))
                roadmap("DeFi / Earn", icon: "chart.line.uptrend.xyaxis", detail: L("message.protocol_positions_yields_and_exits_require_verifiable_adapters_blind_approvals"))
                roadmap("DApp / WalletConnect", icon: "link", detail: L("message.session_permissions_origin_verification_and_request_decoding_require_leak_protection"))
                roadmap(L("message.more_non_evm_transfers"), icon: "point.3.connected.trianglepath.dotted", detail: L("message.btc_ltc_single_key_transparent_addresses_solana_tron_aptos_and"))
                roadmap(L("message.hardware_wallets"), icon: "externaldrive", detail: L("message.native_ledger_trezor_connections_device_confirmation_and_secure_offline_signing"))
            }
        }
    }
    private func roadmap(_ title: String, icon: String, detail: String) -> some View {
        Panel(padding: 22) {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Image(systemName: icon).foregroundStyle(Color.veilAccent); Text(title).font(.system(size: 15, weight: .medium)); Spacer(); Pill(text: L("message.planned"), color: .secondary) }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).frame(minHeight: 50, alignment: .top)
            }
        }
    }
}
