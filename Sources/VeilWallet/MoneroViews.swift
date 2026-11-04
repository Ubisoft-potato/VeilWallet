import SwiftUI
import WalletCore

struct MoneroStatusView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var height = "0"
    var body: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LS(model.monero.status)).font(.system(size: 14, weight: .medium))
                Text(L("message.bip39_accounts_use_ledger_derivation_and_are_not_interchangeable_with"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    TextField(L("message.restore_height_0_scans_from_genesis"), text: $height).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button(L("message.save_restore_height")) {
                        guard let value = UInt64(height), let walletID = model.walletID else { model.error = L("message.restore_height_must_be_a_nonnegative_integer"); return }
                        model.local.moneroRestoreHeights = model.local.moneroRestoreHeights ?? [:]; model.local.moneroRestoreHeights?[walletID.uuidString] = value
                        model.monero.stop(); model.balances = [:]
                        Task { do { try await model.saveLocal() } catch { model.error = error.localizedDescription } }
                    }.disabled(model.busy)
                    if model.busy { Button(L("message.cancel_scan")) { model.monero.stop() } }
                    else { Button(L("message.sync_locally_through_tor")) { Task { await model.refresh() } }.disabled(!model.ready || model.wallet?.canSign != true) }
                }
                Text(L("message.a_restore_height_that_is_too_high_misses_earlier_receipts"))
                    .font(.system(size: 10)).foregroundStyle(.orange)
                if let balance = model.monero.balance { Text(L("message.unlocked_and_spendable") + Ethereum.formatUnits(balance.unlocked, decimals: 12, precision: 12) + " XMR").font(.system(size: 12)) }
            }
        }.onAppear { height = String(model.moneroRestoreHeight) }
    }
}

struct MoneroSendView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var recipient = ""
    @ViewState private var amount = ""
    @ViewState private var password = ""
    @ViewState private var proposal: MoneroProposal?
    @ViewState private var hash: String?
    @ViewState private var error: String?
    @ViewState private var busy = false
    init(initialDraft: TransferDraft? = nil) { _recipient = ViewState(initialValue: initialDraft?.recipient ?? ""); _amount = ViewState(initialValue: initialDraft?.amount ?? "") }
    var body: some View {
        SheetFrame(title: L("message.send_xmr"), subtitle: L("message.the_official_local_runtime_builds_and_signs_broadcasting_through_tor")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FieldLabel(title: L("message.monero_mainnet_receiving_address")) { TextField(L("message.standard_subaddress_integrated_address"), text: $recipient).disabled(proposal != nil || busy) }
                    FieldLabel(title: L("message.xmr_amount")) { TextField("0.00", text: $amount).disabled(proposal != nil || busy) }
                    Text(L("message.building_an_xmr_preview_creates_a_signature_locally_without_broadcasting"))
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    if let proposal {
                        Panel(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L("message.send_39d6f115") + Ethereum.formatUnits(proposal.amount, decimals: 12, precision: 12) + " XMR")
                                Text(L("message.actual_fee") + Ethereum.formatUnits(proposal.fee, decimals: 12, precision: 12) + " XMR")
                                Text(L("message.receive_at") + proposal.recipient).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text(L("message.local_hash_fdf7c01f") + proposal.hash).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                Text(L("message.the_preview_expires_in_90_seconds_and_has_not_been")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let hash { Text(L("message.submitted") + hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    else {
                        FieldLabel(title: proposal == nil ? L("message.vault_password_build_local_signed_preview") : L("message.verify_vault_password_again_approve_broadcast")) { SecureField(L("message.enter_password"), text: $password) }
                        ErrorText(text: error)
                        Button(proposal == nil ? L("message.build_signed_preview_do_not_broadcast") : L("message.approve_broadcasting_this_transaction")) { execute() }
                            .buttonStyle(PrimaryButton()).disabled(busy || password.isEmpty || !model.ready || (proposal?.isExpired ?? false))
                    }
                }
            }.frame(height: proposal == nil ? 360 : 560)
        }.onDisappear { password = ""; proposal = nil }
    }
    private func execute() {
        busy = true; error = nil; let wallet = model.walletID
        Task {
            defer { busy = false; password = "" }
            do {
                if let proposal { hash = try await model.broadcastMonero(proposal: proposal, password: password) }
                else {
                    let result = try await model.prepareMonero(recipient: recipient, amount: amount, password: password)
                    guard model.unlocked, model.walletID == wallet, model.chain.family == .monero else { return }; proposal = result
                }
            } catch { self.error = error.localizedDescription; proposal = nil }
        }
    }
}
