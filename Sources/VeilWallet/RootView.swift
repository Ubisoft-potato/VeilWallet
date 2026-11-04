import SwiftUI
import WalletCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if model.unlocked { workspace } else { UnlockView() }
        }
        .environment(\.locale, WalletLanguage.current.locale)
        .background(Color.veilBackground)
        .tint(.veilAccent)
        .buttonStyle(SecondaryButton())
        .disclosureGroupStyle(WalletDisclosureStyle())
        .controlSize(.large)
        .task(id: model.assetRefreshKey) { await model.runAutomaticAssetRefresh() }
        .task(id: model.marketRefreshKey) { await model.runAutomaticMarketRefresh() }
        .sheet(item: $model.sheet, onDismiss: { model.transferDraft = nil }) { sheet in
            Group {
                switch sheet {
                case .addWallet: AddWalletView()
                case .send: if model.chain.isEVM { SendView(initialDraft: model.transferDraft) } else if model.chain.family == .monero { MoneroSendView(initialDraft: model.transferDraft) } else { NativeSendView(initialDraft: model.transferDraft) }
                case .contract: ContractCallView()
                case .swap:
                    if model.chain.family == .tron { TronDexSwapView() }
                    else { DexSwapView() }
                case .receive: ReceiveView()
                case .bridge: BridgeView()
                case .privacyPool: PrivacyPoolView()
                case .token: AddTokenView()
                case .backup: BackupView()
                case .manage: ManageWalletView()
                }
            }.environmentObject(model).preferredColorScheme(.dark).environment(\.locale, WalletLanguage.current.locale)
        }
        .alert(L("message.action_not_completed"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("message.ok")) { model.error = nil }
        } message: { Text(LS(model.error ?? "")) }
    }
    private var workspace: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 236)
            Rectangle().fill(Color.veilBorder).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Color.veilBorder).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let notice = model.notice { Panel(padding: 16) { ErrorText(text: notice) } }
                        switch model.route {
                        case .assets: AssetsView()
                        case .accounts: AccountsView()
                        case .networks: NetworksView()
                        case .activity: ActivityView()
                        case .discover: DiscoverView()
                        case .privacy: PrivacyView()
                        case .settings: SettingsView()
                        }
                    }.padding(34).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 29)).foregroundStyle(Color.veilAccent)
                Text(L("brand.wordmark")).font(.system(size: 29, weight: .semibold)).tracking(-1)
            }.padding(.top, 32).padding(.bottom, 5)
            Text(L("brand.tagline")).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(.secondary)
                .padding(.bottom, 38)
            ForEach(Array(Route.allCases.enumerated()), id: \.element.id) { index, route in
                SidebarRow(title: route.title, symbol: route.icon, selected: model.route == route) { model.route = route }
                    .accessibilityIdentifier("navigation." + route.id)
                    .interactionFrame("navigation." + route.id)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .help(route.title + " · ⌘" + String(index + 1))
                    .padding(.bottom, 6)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Circle().fill(model.gate.isReady ? Color.veilGreen : .orange).frame(width: 6, height: 6); Text(model.tor.state.label).font(.system(size: 11)) }
                Text(L("message.no_analytics_sdk_no_registration_socks5_remote_dns")).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 12))
            SidebarRow(title: L("wallet.lock"), symbol: "lock", selected: false) { model.lock() }.padding(.vertical, 12)
        }.padding(.horizontal, 16).background(LinearGradient(colors: [Color.veilPanel.opacity(0.55), .veilBackground], startPoint: .top, endPoint: .bottom))
    }
    private var toolbar: some View {
        HStack {
            Picker(L("message.wallet"), selection: $model.walletID) {
                Text(L("message.select_wallet")).tag(Optional<UUID>.none)
                ForEach(model.wallets) { wallet in Text(wallet.name + (wallet.canSign ? "" : L("message.watch_only"))).tag(Optional(wallet.id)) }
            }.labelsHidden().frame(width: 200).disabled(model.busy)
            IconButton(symbol: "plus", title: L("message.add_wallet")) { model.sheet = .addWallet }.padding(.leading, 6).disabled(model.busy)
            Spacer()
            if model.chain.isTestnet { Pill(text: L("message.test_network"), color: .orange) }
            NetworkSwitcher().disabled(model.busy)
            Button { Task { await model.refresh() } } label: {
                Group { if model.busy || model.discovering { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }.frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(filled: true, cornerRadius: 10)).accessibilityLabel(L("message.refresh_balances")).help(L("message.refresh_current_network_balances"))
                .disabled(!model.ready || model.discovering || model.account == nil || !model.canQueryBalance).padding(.leading, 8)
        }.padding(.horizontal, 34).frame(height: 72)
            .onChange(of: model.walletID) { _, _ in model.selectionChanged() }
            .onChange(of: model.chainID) { _, _ in model.selectionChanged() }
    }
}
struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    @ViewState private var error: String?
    @ViewState private var failedAttempts = 0
    @ViewState private var waiting = false
    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 25) {
                HStack { Image(systemName: "shield.lefthalf.filled"); Text(L("brand.wordmark")).tracking(-2) }.font(.system(size: 44, weight: .medium)).foregroundStyle(Color.veilAccent)
                Text(L("message.your_assets_your_quiet")).font(.system(size: 42, weight: .semibold)).lineSpacing(10)
                Text(L("message.native_macos_self_custody_wallet_keys_generated_locally_chain_requests")).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(8)
                HStack(spacing: 8) { Pill(text: L("message.local_signing")); Pill(text: L("message.remote_dns")); Pill(text: L("message.network_kill_switch")) }.padding(.top, 16)
                Text(L("message.development_preview_no_independent_security_audit")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 30)
            }.frame(width: 450, alignment: .leading)
            Panel(padding: 32) {
                VStack(alignment: .leading, spacing: 22) {
                    Text(model.hasVault ? L("message.welcome_back") : L("message.create_a_local_vault")).font(.system(size: 25, weight: .semibold))
                    Text(model.hasVault ? L("message.enter_your_password_to_decrypt_the_local_wallet") : L("message.use_a_unique_password_with_at_least_12_characters_it"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    FieldLabel(title: L("message.vault_password")) { SecureField(L("message.at_least_12_characters"), text: $password).onSubmit { authenticate() } }
                    if !model.hasVault { FieldLabel(title: L("message.confirm_password")) { SecureField(L("message.enter_password_again"), text: $confirmation).onSubmit { authenticate() } } }
                    ErrorText(text: error)
                    Button { authenticate() } label: {
                        HStack { if model.busy || waiting { ProgressView().controlSize(.small) }; Text(model.hasVault ? L("message.unlock_wallet") : L("message.create_vault")); Spacer(); Image(systemName: "arrow.right") }.frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryButton()).disabled(model.busy || model.authenticating || waiting || password.isEmpty)
                    LanguagePreferenceView(compact: true)
                    Divider()
                    Label(L("message.tor_and_blockchain_connections_start_only_after_unlock"), systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(width: 370)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
    private func authenticate() {
        guard !model.busy, !waiting else { return }
        if !model.hasVault && password != confirmation { error = L("message.the_two_passwords_do_not_match"); return }
        let value = password; error = nil
        Task {
            do {
                try await model.authenticate(password: value, create: !model.hasVault)
                password = ""; confirmation = ""; failedAttempts = 0
            } catch {
                self.error = error.localizedDescription; failedAttempts += 1; waiting = true
                try? await Task.sleep(for: .seconds(min(30, failedAttempts * 2)))
                waiting = false
            }
        }
    }
}
