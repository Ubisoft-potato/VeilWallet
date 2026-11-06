import SwiftUI
import AppKit
import WalletCore
import CoreImage.CIFilterBuiltins

struct SheetFrame<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 24, weight: .semibold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4) }
                Spacer()
                IconButton(symbol: "xmark", title: L("action.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            content
        }.padding(30).frame(width: 580).background(Color.veilBackground)
            .buttonStyle(SecondaryButton()).disclosureGroupStyle(WalletDisclosureStyle()).controlSize(.large)
    }
}
struct AddWalletView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var mode = 0
    @ViewState private var name = L("wallet.default_name")
    @ViewState private var material = ""
    @ViewState private var mnemonicDraft = MnemonicImportDraft()
    @ViewState private var passphrase = ""
    @ViewState private var accountIndex = "0"
    @ViewState private var selectedProfile = "evm"
    @ViewState private var advanced = false
    @ViewState private var overrideProfile = "evm"
    @ViewState private var overridePath = ""
    @ViewState private var overrides: [String: String] = [:]
    @ViewState private var generated = ""
    @ViewState private var wordCount = 12
    @ViewState private var quiz: [Int] = []
    @ViewState private var answers = ["", "", ""]
    @ViewState private var reviewed: [WalletAccount] = []
    @ViewState private var error: String?
    @ViewState private var busy = false
    init(mode: Int = 0, previewAccounts: [WalletAccount] = [], mnemonicWordCount: Int = 12) {
        _mode = ViewState(initialValue: mode)
        _reviewed = ViewState(initialValue: previewAccounts)
        _mnemonicDraft = ViewState(initialValue: MnemonicImportDraft(count: mnemonicWordCount))
    }
    private var profile: AccountProfile { AccountProfile.find(selectedProfile) ?? .evm }
    var body: some View {
        SheetFrame(title: reviewed.isEmpty ? L("message.add_a_multichain_wallet") : L("message.confirm_imported_addresses"), subtitle: L("message.recovery_phrases_private_keys_and_addresses_are_validated_locally_and")) {
            if reviewed.isEmpty {
                ScrollView { form.padding(.trailing, 4) }
                    .scrollBounceBehavior(.basedOnSize).frame(height: mode >= 2 ? 300 : mode == 1 ? importHeight : 420)
            } else { review }
            ErrorText(text: error)
            HStack {
                if !reviewed.isEmpty { Button(L("message.back_to_edit")) { reviewed = [] }.disabled(busy) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? L("message.processing") : reviewed.isEmpty ? L("message.validate_and_preview_addresses") : L("message.confirm_and_save_wallet")) {
                    if reviewed.isEmpty { preview() } else { save() }
                }.buttonStyle(PrimaryButton()).disabled(busy || (mode == 0 && generated.isEmpty) || (mode == 1 && !mnemonicDraft.isValid))
            }
        }.onChange(of: wordCount) { _, _ in generated = ""; answers = ["", "", ""] }
            .onChange(of: mode) { _, _ in error = nil; material = ""; mnemonicDraft.clear(); if mode == 2 && !profile.supportsKeyImport { selectedProfile = "ltc.segwit" } }
            .onDisappear { material = ""; mnemonicDraft.clear(); generated = ""; passphrase = ""; answers = ["", "", ""]; reviewed = [] }
    }
    private var importHeight: CGFloat { min(520, max(340, (NSScreen.main?.visibleFrame.height ?? 820) - 260)) }
    private var form: some View {
        VStack(alignment: .leading, spacing: 17) {
            Picker(L("message.method"), selection: $mode) {
                Text(L("message.create")).tag(0); Text(L("message.recovery_phrase")).tag(1); Text(L("message.private_key")).tag(2); Text(L("message.watch_only_531c2354")).tag(3)
            }.pickerStyle(.segmented)
            FieldLabel(title: L("message.wallet_name")) { TextField(L("wallet.default_name"), text: $name) }
            if mode >= 2 {
                Picker(L("message.key_family_address_type"), selection: $selectedProfile) {
                    ForEach(mode == 2 ? AccountProfile.all.filter(\.supportsKeyImport) : AccountProfile.all) { item in Text(item.name).tag(item.id) }
                }
                FieldLabel(title: mode == 3 ? (profile.family == .eos ? L("message.on_chain_account_name") : profile.family == .starknet ? L("message.starknet_account_contract_address_not_a_public_key") : L("message.address_on_the_selected_network")) : profile.keyHint) {
                    if mode == 3 { TextField(L("message.address_account_name"), text: $material).font(.system(size: 11, design: .monospaced)) }
                    else { SecureField(L("message.decrypted_and_stored_locally_only"), text: $material).font(.system(size: 11, design: .monospaced)) }
                }
                Text(mode == 3 ? L("message.watch_only_wallets_store_addresses_and_cannot_sign") : L("message.a_private_key_imports_only_into_its_selected_key_family"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                if profile.family == .bitcoin { Text(L("message.choose_legacy_for_uncompressed_wif_starting_with_5_segwit_and")).font(.system(size: 11)).foregroundStyle(.secondary) }
                if profile.family == .litecoin {
                    Text(profile.id == "ltc.mweb" ? L("message.mweb_uses_a_scan_key_and_master_spend_key_a") : L("message.l_m_legacy_3_ltc1q_ltc1p_formats_are_validated_separately"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
                if profile.family == .polkadot { Text(L("message.this_is_ed25519_bip44_sr25519_suri_and_encrypted_json_keystores")).font(.system(size: 11)).foregroundStyle(.orange) }
            } else {
                Pill(text: L("message.derives_every_supported_key_family_0_networks_identity_protocols", NetworkCatalog.chains.count))
                if mode == 0 {
                    HStack {
                        Picker(L("message.word_count"), selection: $wordCount) { Text(L("message.12_words")).tag(12); Text(L("message.24_words")).tag(24) }.frame(width: 155)
                        Spacer(); Button(generated.isEmpty ? L("message.generate_recovery_phrase") : L("message.generate_again")) { generate() }
                    }
                    if !generated.isEmpty {
                        MnemonicGrid(phrase: generated)
                        Text(L("message.write_this_down_offline_the_phrase_and_passphrase_together_determine")).font(.system(size: 11)).foregroundStyle(.orange)
                        HStack {
                            ForEach(0..<quiz.count, id: \.self) { i in
                                FieldLabel(title: L("message.word_0", quiz[i] + 1)) { SecureField(L("message.confirm_backup"), text: $answers[i]) }
                            }
                        }
                    }
                } else {
                    MnemonicInputGrid(draft: $mnemonicDraft)
                }
                FieldLabel(title: L("message.bip39_passphrase_optional_changes_every_address_and_cannot_be_recovered")) { SecureField(L("message.leave_blank_for_no_passphrase"), text: $passphrase) }
                FieldLabel(title: L("message.account_address_index_each_chain_uses_its_standard_path")) { TextField("0", text: $accountIndex) }
                DisclosureGroup(L("message.advanced_custom_derivation_paths"), isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(L("message.account_family_to_override"), selection: $overrideProfile) { ForEach(AccountProfile.derivable) { item in Text(item.name).tag(item.id) } }
                        HStack {
                            TextField(AccountProfile.find(overrideProfile)?.path(index: UInt32(accountIndex) ?? 0) ?? "m/…", text: $overridePath).textFieldStyle(.roundedBorder)
                            Button(L("message.apply_path")) {
                                let path = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
                                if path.isEmpty { overrides[overrideProfile] = nil } else { overrides[overrideProfile] = path }
                            }
                        }
                        Text(L("message.apply_an_empty_value_to_restore_the_default_record_custom")).font(.system(size: 10)).foregroundStyle(.secondary)
                        ForEach(overrides.keys.sorted(), id: \.self) { id in Text((AccountProfile.find(id)?.name ?? id) + " · " + (overrides[id] ?? "")).font(.system(size: 10, design: .monospaced)) }
                    }.padding(.top, 10)
                }

            }
        }.disabled(busy)
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(name).font(.system(size: 17, weight: .semibold)); Spacer(); Pill(text: mode <= 1 ? L("message.multichain_recovery_phrase") : mode == 2 ? L("message.selected_network_private_key") : L("message.read_only_watch_wallet")) }
            Text(L("message.compare_these_with_receiving_addresses_in_your_existing_wallet_derivation"))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(reviewed) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(account.profile?.name ?? account.profileID).font(.system(size: 12, weight: .medium)); Spacer(); if account.requiresBinding && !account.isBound { Pill(text: L("message.authority_public_key_not_linked"), color: .orange) } }
                            Text(account.networkAddress).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let index = account.addressIndex { Text(L("message.mweb_subaddress_index_0", index)).font(.system(size: 10)).foregroundStyle(.secondary) }
                            if let path = account.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }.frame(height: min(340, CGFloat(reviewed.count) * 94))
            if reviewed.contains(where: { $0.requiresBinding }) { Text(L("message.eos_wax_requires_an_on_chain_account_name_starknet_requires")).font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(4) }
        }
    }
    private func generate() {
        do { generated = try Mnemonic.generate(wordCount: wordCount); quiz = Array((0..<wordCount).shuffled().prefix(3)).sorted(); answers = ["", "", ""]; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func preview() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40 else { error = L("message.wallet_names_must_contain_1_40_characters"); return }
        if mode == 0 {
            let words = generated.split(separator: " ").map(String.init)
            guard quiz.count == 3, zip(quiz, answers).allSatisfy({ words[$0.0] == $0.1.trimmingCharacters(in: .whitespaces).lowercased() }) else { error = L("message.complete_the_recovery_phrase_backup_check"); return }
        }
        guard let index = UInt32(accountIndex), index < 0x80000000 else { error = L("message.the_index_must_be_between_0_and_2147483647"); return }
        if mode == 1 && !mnemonicDraft.isValid { error = L("message.the_recovery_phrase_contains_invalid_words_or_a_wrong_checksum"); return }
        let value = mode == 0 ? generated : mode == 1 ? mnemonicDraft.phrase : material
        let phrasePassword = passphrase; let profile = profile; let selectedMode = mode; let customPaths = overrides
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached {
                    if selectedMode <= 1 { return try MultichainCrypto.deriveAccounts(phrase: value, passphrase: phrasePassword, index: index, overrides: customPaths) }
                    if selectedMode == 2 { return [try MultichainCrypto.importPrivateKey(value, profile: profile)] }
                    guard MultichainCrypto.validateAddress(value, profile: profile) else { throw WalletError.invalid(L("message.the_address_format_or_checksum_does_not_match_the_selected")) }
                    return [WalletAccount(profileID: profile.id, address: value, boundAddress: [.eos, .starknet].contains(profile.family) ? value : nil)]
                }.value
                guard model.unlocked else { return }; reviewed = result
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        guard let index = UInt32(accountIndex) else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await model.addWallet(name: name, kind: mode <= 1 ? .mnemonic : mode == 2 ? .privateKey : .watch,
                    material: mode == 0 ? generated : mode == 1 ? mnemonicDraft.phrase : material, passphrase: passphrase, account: index, profileID: selectedProfile, overrides: overrides)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
struct MnemonicGrid: View {
    let phrase: String
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
            ForEach(Array(phrase.split(separator: " ").enumerated()), id: \.offset) { item in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", item.offset + 1)).foregroundStyle(.secondary).font(.system(size: 9, design: .monospaced))
                    Text(String(item.element)).font(.system(size: 12, weight: .medium, design: .monospaced)); Spacer(minLength: 0)
                }.padding(10).background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 7))
            }
        }.privacySensitive()
    }
}
struct ReceiveView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        SheetFrame(title: L("message.receive_asset"), subtitle: L("message.confirm_the_sender_uses_the_same_network_the_qr_code")) {
            if let account = model.account, account.isBound {
                VStack(spacing: 20) {
                    if let image = qr(receiveURI(account.networkAddress)) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200).padding(15).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Pill(text: model.chain.name)
                    Text(account.networkAddress).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !account.supportsPublicBalanceQuery && model.chain.family == .litecoin {
                        Text(L("message.mweb_balance_scanning_and_sending_are_not_available_in_this")).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    ClipboardCopyButton(text: account.networkAddress, title: L("message.copy_address")).buttonStyle(PrimaryButton())
                    Text(L("message.the_clipboard_clears_after_30_seconds_check_the_address_character")).font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 15)
            }
        }
    }
    private func receiveURI(_ address: String) -> String {
        switch model.chain.family {
        case .evm: return "ethereum:\(address)@\(model.chainID)"
        case .bitcoin: return "bitcoin:" + address
        case .litecoin: return "litecoin:" + address
        case .monero: return "monero:" + address
        case .solana: return "solana:" + address
        case .ton: return "ton://transfer/" + address
        case .nostr: return "nostr:" + address
        default: return address
        }
    }
    private func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
struct AddTokenView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var contract = ""
    @ViewState private var symbol = ""
    @ViewState private var decimals = "18"
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var mode = 0
    @ViewState private var search = ""
    var body: some View {
        SheetFrame(title: L("message.manage_tokens"), subtitle: L("message.bundled_contracts_and_icons_are_local_verify_network_address_and")) {
            Pill(text: model.chain.name)
            Picker(L("message.token_source"), selection: $mode) { Text(L("message.bundled_tokens")).tag(0); Text(L("message.custom_tokens")).tag(1) }.pickerStyle(.segmented)
            if mode == 0 {
                TextField(L("message.search_tokens_or_contracts"), text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(TokenCatalog.all.filter { $0.chainID == model.chainID && (search.isEmpty || [$0.symbol,$0.name,$0.contract].joined(separator: " ").localizedCaseInsensitiveContains(search)) }) { preset in
                            HStack(spacing: 12) {
                                AssetLogo(chain: model.chain, token: preset.token, size: 36)
                                VStack(alignment: .leading, spacing: 5) { Text(preset.symbol + " · " + preset.name).font(.system(size: 13, weight: .medium)); Text(LK(preset.provenance) + L("message.decimals_0", preset.decimals)).font(.system(size: 10)).foregroundStyle(Color.veilAccent); Text(preset.contract).font(.system(size: 9, design: .monospaced)).textSelection(.enabled) }
                                Spacer()
                                ClipboardCopyButton(text: preset.contract, title: L("message.copy_contract"), iconOnly: true)
                            }
                        }
                    }
                }.frame(height: 330)
                Text(L("message.bundled_tokens_are_queried_automatically_native_issued_bridged_and_legacy")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
            FieldLabel(title: L("message.contract_address")) { TextField(model.chain.family == .tron ? "T…" : "0x…", text: $contract) }
            HStack {
                FieldLabel(title: L("message.token_symbol")) { TextField(L("placeholder.token_symbol"), text: $symbol) }
                FieldLabel(title: L("message.decimals_0_36")) { TextField("18", text: $decimals) }
            }
            Text(L("message.token_lists_and_icons_are_not_downloaded_at_runtime_symbols")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            ErrorText(text: error)
            HStack { Spacer(); Button(L("message.add_token")) {
                do {
                    guard let places = Int(decimals) else { throw WalletError.invalid(L("message.invalid_decimals")) }
                    let token = try Token(chainID: model.chainID, contract: contract, symbol: symbol, decimals: places)
                    guard !TokenCatalog.merged(with: model.local.tokens).contains(where: { $0.id == token.id }) else { throw WalletError.invalid(L("message.the_token_is_bundled_or_already_added")) }
                    busy = true; model.local.tokens.append(token)
                    Task {
                        defer { busy = false }
                        do { try await model.saveLocal(); dismiss() }
                        catch { model.local.tokens.removeAll { $0.id == token.id }; self.error = error.localizedDescription }
                    }
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(PrimaryButton()).disabled(busy) }
            }
        }
    }
}
struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var material: String?
    @ViewState private var passphrase = ""
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var visibility = UUID()
    var body: some View {
        SheetFrame(title: L("message.offline_backup"), subtitle: L("message.recovery_phrases_and_private_keys_are_not_copied_to_the")) {
            if let material {
                if model.wallet?.kind == .mnemonic { MnemonicGrid(phrase: material) }
                else { Text(material).font(.system(size: 12, design: .monospaced)).privacySensitive() }
                if !passphrase.isEmpty { Text(L("message.bip39_passphrase_0", passphrase)).font(.system(size: 12, design: .monospaced)).privacySensitive() }
                Text(L("message.the_backup_is_hidden_when_the_window_closes_the_app")).font(.system(size: 12)).foregroundStyle(.orange)
            } else {
                FieldLabel(title: L("message.verify_vault_password_again")) { SecureField(L("message.password"), text: $password) }
                ErrorText(text: error)
                Button(busy ? L("message.verifying") : L("message.reveal_backup")) {
                    guard let id = model.walletID else { return }; busy = true
                    let request = visibility
                    Task {
                        defer { busy = false; password = "" }
                        do {
                            let value = try await model.vault.reveal(walletID: id, password: password)
                            guard model.unlocked, model.walletID == id, NSApplication.shared.isActive, request == visibility else { return }
                            material = value.material; passphrase = value.passphrase
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(PrimaryButton()).disabled(busy)
            }
        }.onDisappear { visibility = UUID(); material = nil; passphrase = ""; password = "" }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in visibility = UUID(); material = nil; passphrase = ""; password = "" }
    }
}

struct ManageWalletView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var mode = 0
    @ViewState private var name = ""
    @ViewState private var password = ""
    @ViewState private var replacement = ""
    @ViewState private var confirmation = ""
    @ViewState private var backedUp = false
    @ViewState private var busy = false
    @ViewState private var error: String?
    var body: some View {
        SheetFrame(title: L("message.manage_wallet"), subtitle: L("message.0_local_settings", model.wallet?.name ?? "")) {
            Picker(L("message.action"), selection: $mode) { Text(L("message.rename")).tag(0); Text(L("message.change_password")).tag(1); Text(L("message.remove_wallet")).tag(2) }.pickerStyle(.segmented).disabled(busy)
            if mode == 0 {
                FieldLabel(title: L("message.wallet_name")) { TextField(L("message.name"), text: $name) }
            } else {
                FieldLabel(title: L("message.current_vault_password")) { SecureField(L("message.current_password"), text: $password) }
                if mode == 1 {
                    FieldLabel(title: L("message.new_password_at_least_12_characters")) { SecureField(L("message.new_password"), text: $replacement) }
                    FieldLabel(title: L("message.confirm_new_password")) { SecureField(L("message.enter_new_password_again"), text: $confirmation) }
                    Text(L("message.this_re_encrypts_the_entire_vault_and_applies_to_every")).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(L("message.removal_deletes_this_wallet_s_local_keys_and_cannot_be")).font(.system(size: 12)).foregroundStyle(.orange).lineSpacing(5)
                    Toggle(L("message.i_backed_up_my_recovery_information_offline"), isOn: $backedUp)
                }
            }
            ErrorText(text: error)
            HStack { Spacer(); Button(busy ? L("message.saving") : mode == 2 ? L("message.remove_local_wallet") : L("message.save_changes")) { apply() }
                .buttonStyle(PrimaryButton(bodyColor: mode == 2 ? .orange : .veilAccent)).disabled(busy || (mode == 2 && !backedUp)) }
        }.onAppear { name = model.wallet?.name ?? "" }
            .onChange(of: mode) { _, _ in password = ""; replacement = ""; confirmation = ""; error = nil }
            .onDisappear { password = ""; replacement = ""; confirmation = "" }
    }
    private func apply() {
        guard let id = model.walletID else { return }
        if mode == 1 && replacement != confirmation { error = L("message.the_new_passwords_do_not_match"); return }
        busy = true; error = nil
        Task {
            defer { busy = false; password = ""; replacement = ""; confirmation = "" }
            do {
                if mode == 0 { try await model.vault.rename(walletID: id, name: name) }
                else if mode == 1 { try await model.vault.changePassword(current: password, replacement: replacement) }
                else { try await model.vault.remove(walletID: id, password: password) }
                guard model.unlocked else { return }
                model.wallets = try await model.vault.summaries()
                if mode == 2 { model.walletID = model.wallets.first?.id; model.selectionChanged() }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
