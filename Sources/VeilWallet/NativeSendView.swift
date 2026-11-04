import SwiftUI
import WalletCore

struct NativeSendView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var recipient = ""
    @ViewState private var amount = ""
    @ViewState private var memo = ""
    @ViewState private var gasPrice = ""
    @ViewState private var password = ""
    @ViewState private var plan: NativeTransferPlan?
    @ViewState private var error: String?
    @ViewState private var hash: String?
    @ViewState private var busy = false
    init(initialDraft: TransferDraft? = nil) {
        _recipient = ViewState(initialValue: initialDraft?.recipient ?? ""); _amount = ViewState(initialValue: initialDraft?.amount ?? ""); _memo = ViewState(initialValue: initialDraft?.memo ?? "")
    }
    var body: some View {
        SheetFrame(title: L("message.send_43b7b608") + model.chain.symbol, subtitle: model.chain.name + L("message.local_signing_and_tor_broadcast")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FieldLabel(title: L("message.receiving_address_check_the_network_and_full_address")) { TextField(L("message.receiving_address"), text: $recipient).disabled(plan != nil || busy) }
                    FieldLabel(title: L("message.amount_to_send")) { TextField("0.00", text: $amount).disabled(plan != nil || busy) }
                    if model.chain.family == .cosmos {
                        FieldLabel(title: L("message.memo_exchanges_may_require_it_published_on_chain")) { TextField(L("message.optional_up_to_256_bytes"), text: $memo).disabled(plan != nil || busy) }
                        FieldLabel(title: L("message.gas_price") + (model.chain.denomination ?? L("message.base_units")) + "/Gas") { TextField(L("message.leave_blank_to_query_the_node_enter_manually_if_unavailable"), text: $gasPrice).disabled(plan != nil || busy) }
                    }
                    if let plan {
                        Panel(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L("message.send_39d6f115") + Ethereum.formatUnits(plan.amount, decimals: model.chain.decimals, precision: model.chain.decimals) + " " + model.chain.symbol)
                                Text(L("message.fee_budget") + Ethereum.formatUnits(plan.feeBudget, decimals: model.chain.decimals, precision: model.chain.decimals) + " " + model.chain.symbol)
                                Text(L("message.from") + plan.sender).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text(L("message.to") + plan.recipient).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                ForEach(plan.details, id: \.self) { detail in Text(LS(detail)).font(.system(size: 11)).foregroundStyle(.secondary) }
                                Text(L("message.the_preview_expires_in_90_seconds_balance_sequence_or_utxos")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                        if hash == nil { FieldLabel(title: L("message.vault_password_verify_again_for_each_signature")) { SecureField(L("message.enter_password"), text: $password) } }
                    }
                    if let hash { Text(L("message.transaction_hash_f9f11fd9") + hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled); Text(model.transactionStatus(hash: hash)).foregroundStyle(Color.veilGreen) }
                    ErrorText(text: error)
                    if hash == nil {
                        HStack {
                            if plan != nil { Button(L("message.edit_and_rebuild")) { plan = nil; password = "" } }
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Button(plan == nil ? L("message.build_transfer_preview") : L("message.confirm_sign_and_send")) { execute() }.buttonStyle(PrimaryButton()).disabled(busy || !model.ready || (plan != nil && password.isEmpty))
                        }
                    }
                }
            }.frame(height: plan == nil ? (model.chain.family == .cosmos ? 430 : 250) : 570)
        }.onDisappear { password = ""; plan = nil }
    }
    private func execute() {
        busy = true; error = nil
        let chain = model.chainID; let wallet = model.walletID; let account = model.profileID
        Task {
            defer { busy = false; password = "" }
            do {
                if let plan { hash = try await model.sendNative(plan: plan, password: password) }
                else {
                    let prepared = try await model.prepareNative(recipient: recipient, amount: amount, memo: memo, gasPrice: gasPrice.isEmpty ? nil : gasPrice)
                    guard model.unlocked, model.chainID == chain, model.walletID == wallet, model.profileID == account else { return }; plan = prepared
                }
            } catch { self.error = error.localizedDescription; plan = nil }
        }
    }
}
