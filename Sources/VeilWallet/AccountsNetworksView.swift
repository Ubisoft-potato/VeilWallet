import SwiftUI
import WalletCore

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    @ViewState private var binding: WalletAccount?
    var accounts: [WalletAccount] {
        (model.wallet?.allAccounts ?? []).filter { search.isEmpty || ($0.profile?.name ?? "").localizedCaseInsensitiveContains(search) || $0.networkAddress.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(eyebrow: L("section.accounts.eyebrow"), title: L("message.accounts_across_chains"), subtitle: L("message.the_recovery_phrase_derives_accounts_using_each_chain_s_rules"))
            TextField(L("message.search_networks_addresses_or_authority_public_keys"), text: $search).textFieldStyle(.roundedBorder)
            ForEach(accounts) { account in
                Panel(padding: 18) {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text(account.profile?.name ?? account.profileID).font(.system(size: 15, weight: .semibold)); Spacer()
                            if account.requiresBinding && !account.isBound { Pill(text: L("message.on_chain_account_not_linked"), color: .orange) }
                            if account.requiresBinding { Button(account.isBound ? L("message.edit_link") : L("message.link_account")) { binding = account } }
                            else { Button(L("message.copy_address")) { model.copyAddress(account.networkAddress) } }
                        }
                        Text(account.networkAddress).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let index = account.addressIndex { Text(L("message.mweb_subaddress_index_0", index)).font(.system(size: 10)).foregroundStyle(.secondary) }
                        if let path = account.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        let assets = model.fundedAssets(for: account)
                        if !assets.isEmpty {
                            HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.veilGreen); Text(L("message.balance_found_0_assets_networks_view_them_in_assets", assets.count)).font(.system(size: 11)) }
                        }
                        if account.profile?.family == .litecoin, let info = try? Litecoin.addressInfo(account.networkAddress) {
                            Text(info.label + (info.isMWEB ? L("message.balance_scanning_and_sending_are_not_available_yet") : "")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if account.requiresBinding {
                            Text((model.wallet?.kind == .watch ? L("message.watch_only_account") : L("message.authority_public_key")) + account.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(L("message.the_account_name_or_contract_address_follows_the_chain_s"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        }
                    }
                }
            }
        }.sheet(item: $binding) { account in BindAccountView(account: account).environmentObject(model).preferredColorScheme(.dark) }
    }
}
struct BindAccountView: View {
    let account: WalletAccount
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var address = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    var body: some View {
        SheetFrame(title: L("message.link_an_on_chain_account"), subtitle: account.profile?.name ?? account.profileID) {
            Text(L("message.this_network_uses_different_authority_public_keys_and_receiving_addresses"))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            Text(account.address).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            FieldLabel(title: account.profile?.family == .eos ? L("message.eos_wax_account_name") : L("message.starknet_account_contract_address")) { TextField(L("message.account_name_0x"), text: $address) }
            ErrorText(text: error)
            Button(busy ? L("message.saving") : L("message.save_link")) {
                guard let id = model.walletID else { return }; busy = true
                Task {
                    defer { busy = false }
                    do { try await model.vault.bindAccount(walletID: id, profileID: account.profileID, address: address); try await model.reloadWallets(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(PrimaryButton()).disabled(busy)
        }.onAppear { address = account.boundAddress ?? "" }
    }
}
struct NetworksView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    @ViewState private var family: NetworkFamily?
    @ViewState private var mainstreamOnly = false
    var networks: [Chain] { model.local.chains.filter { (!mainstreamOnly || $0.isMainstreamEVM) && (family == nil || $0.family == family) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.symbol.localizedCaseInsensitiveContains(search) || String($0.id) == search) }.sorted { EVMNetworkSupport.rank($0) < EVMNetworkSupport.rank($1) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(eyebrow: L("section.networks.eyebrow"), title: L("message.network_directory"), subtitle: L("message.the_directory_and_icons_are_bundled_locally_search_networks_or"))
            HStack {
                TextField(L("message.search_networks_chain_ids_or_symbols"), text: $search).textFieldStyle(.roundedBorder)
                Toggle(L("message.common_evm"), isOn: $mainstreamOnly).toggleStyle(.switch).fixedSize()
                    .onChange(of: mainstreamOnly) { _, value in if value { family = .evm } }
                Picker(L("message.family"), selection: $family) {
                    Text(L("message.all_families")).tag(Optional<NetworkFamily>.none)
                    ForEach(NetworkFamily.allCases, id: \.self) { item in Text(item.name).tag(Optional(item)) }
                }.frame(width: 180).onChange(of: family) { _, value in if value != .evm { mainstreamOnly = false } }
            }
            Text(L("message.0_entries_updated_1_balance_and_sending_capabilities_are_listed", networks.count, NetworkCatalog.sourceDate))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(networks) { chain in
                Panel(padding: 17) {
                    HStack(spacing: 16) {
                        AssetLogo(chain: chain, size: 34)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(chain.name).font(.system(size: 15, weight: .semibold))
                            Text(chain.isEVM ? "EVM · Chain ID \(chain.id) · \(chain.symbol)" : "\(chain.family.name) · \(chain.symbol)").font(.system(size: 11)).foregroundStyle(.secondary)
                            if chain.isEVM { Text(chain.evmFeeModel.label).font(.system(size: 10)).foregroundStyle(chain.feeNotice == nil ? Color.secondary : .orange) }
                        }
                        Spacer()
                        Pill(text: L("message.import_derive"), color: .veilGreen)
                        Pill(text: chain.canQuery ? (chain.family == .litecoin ? L("message.transparent_address_balance") : L("message.balance_queries")) : L("message.address_identity"), color: chain.canQuery ? .veilGreen : .secondary)
                        if chain.canTransfer { Pill(text: L("message.sending_supported"), color: .veilAccent) }
                        if !chain.configured && chain.family != .nostr { Pill(text: L("message.endpoint_required"), color: .orange) }
                        Button(L("message.select")) { model.chainID = chain.id; model.selectionChanged(); model.route = .assets }
                            .disabled(model.wallet?.accounts(on: chain).isEmpty ?? true)
                    }
                }
            }
        }
    }
}
