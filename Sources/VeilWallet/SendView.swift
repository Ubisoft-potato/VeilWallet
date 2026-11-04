import SwiftUI
import WalletCore
import BigInt

struct SendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var recipient = ""
    @ViewState private var amount = ""
    @ViewState private var asset = "native"
    @ViewState private var password = ""
    @ViewState private var preview: TransactionPreview?
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var sentHash: String?
    @ViewState private var maxFee = ""
    @ViewState private var priorityFee = ""
    init(initialDraft: TransferDraft? = nil) {
        _recipient = ViewState(initialValue: initialDraft?.recipient ?? ""); _amount = ViewState(initialValue: initialDraft?.amount ?? ""); _asset = ViewState(initialValue: initialDraft?.assetID ?? "native")
    }
    var body: some View {
        SheetFrame(title: sentHash == nil ? L("message.send_assets") : L("message.transaction_saved"), subtitle: L("message.0_local_signing_and_tor_broadcast", model.chain.name)) {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            if let sentHash {
                Label(model.transactionStatus(hash: sentHash), systemImage: "checkmark.circle.fill").foregroundStyle(Color.veilGreen)
                Text(sentHash).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Button(L("message.view_activity")) { model.route = .activity; dismiss() }.buttonStyle(PrimaryButton())
            } else {
                Group {
                    Picker(L("message.send_assets"), selection: $asset) {
                        Text(model.chain.symbol + L("message.native_asset")).tag("native")
                        ForEach(model.tokens) { token in Text(token.symbol + " · " + String(token.contract.prefix(10)) + "…").tag(token.id) }
                    }
                    FieldLabel(title: L("message.receiving_address_automatic_ens_resolution_is_unsupported")) { TextField(L("placeholder.evm_address"), text: $recipient).font(.system(size: 12, design: .monospaced)) }
                    FieldLabel(title: L("message.amount")) { TextField("0.00", text: $amount) }
                }.disabled(busy || preview != nil)
                if let preview {
                    Panel(padding: 16) {
                        VStack(alignment: .leading, spacing: 11) {
                            detail(L("message.send"), "\(preview.amount) \(preview.symbol)")
                            detail(L("message.receiving_address"), preview.recipient)
                            if let token = preview.token { detail(L("message.token_contract"), token.contract) }
                            detail("Chain ID / Nonce", "\(preview.transaction.chainID) / \(preview.transaction.nonce)")
                            detail(L("message.gas_limit"), String(preview.transaction.gasLimit))
                            detail(L("message.maximum_execution_fee"), Ethereum.formatUnits(preview.transaction.maximumFee, decimals: model.chain.decimals, precision: 18) + " " + model.chain.symbol)
                            if [.opStack, .mantle, .scroll].contains(model.chain.evmFeeModel) {
                                detail(L("message.estimated_l1_data_fee"), Ethereum.formatUnits(preview.additionalFees.l1DataFee, decimals: model.chain.decimals, precision: 18) + " " + model.chain.symbol)
                                if [.opStack, .mantle].contains(model.chain.evmFeeModel) { detail(L("message.estimated_operator_fee"), Ethereum.formatUnits(preview.additionalFees.operatorFee, decimals: model.chain.decimals, precision: 18) + " " + model.chain.symbol) }
                                detail(L("message.total_fee_budget"), Ethereum.formatUnits(preview.totalFeeBudget, decimals: model.chain.decimals, precision: 18) + " " + model.chain.symbol)
                            }
                            if let notice = model.chain.feeNotice { Text(notice).font(.system(size: 10)).foregroundStyle(.orange) }
                            detail(preview.transaction.mode == .legacy ? L("fee.legacy_gas_price") : L("message.maximum_priority_fee_gwei_c4e48f34"), Ethereum.formatUnits(preview.transaction.maxFee, decimals: 9) + (preview.transaction.mode == .legacy ? "" : " / " + Ethereum.formatUnits(preview.transaction.maxPriorityFee, decimals: 9)))
                            Text(L("message.the_preview_expires_in_90_seconds_additional_fee_budgets_include"))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                        }
                    }
                    DisclosureGroup(L("message.adjust_fee_rates")) {
                        VStack(alignment: .leading, spacing: 10) {
                            FieldLabel(title: preview.transaction.mode == .legacy ? L("fee.gas_price") : L("message.maximum_fee_gwei")) { TextField(L("unit.gwei"), text: $maxFee) }
                            if preview.transaction.mode == .eip1559 { FieldLabel(title: L("message.priority_fee_gwei")) { TextField(L("unit.gwei"), text: $priorityFee) } }
                            Button(L("message.revalidate_fees")) { reprice(preview) }.disabled(busy || !model.ready)
                            Text(L("message.signing_uses_the_validated_preview_above_revalidate_after_editing_the")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.top, 8).disabled(busy)
                    }
                    FieldLabel(title: L("message.vault_password_required_for_every_signature")) { SecureField(L("message.enter_password_to_sign"), text: $password) }.disabled(busy)
                }
                ErrorText(text: error)
                if let notice = model.notice { ErrorText(text: notice) }
                HStack {
                    if preview != nil { Button(L("message.edit_transaction")) { preview = nil; password = ""; error = nil }.disabled(busy) }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(preview == nil ? L("message.estimate_fees_and_preview") : L("message.confirm_sign_and_send")) {
                        if let preview { send(preview) } else { prepare() }
                    }.buttonStyle(PrimaryButton()).disabled(busy || !model.ready || (preview != nil && password.isEmpty))
                }
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 620)
        }.onDisappear { password = ""; preview = nil }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func prepare() {
        guard let wallet = model.wallet, let account = model.account, model.chain.isEVM else { return }; busy = true; error = nil
        let client = model.client(); let chainID = model.chainID
        let token = model.tokens.first { $0.id == asset }
        Task {
            defer { busy = false }
            do {
                let result = try await client.prepare(sender: account.networkAddress, recipient: recipient, amount: amount, token: token)
                guard model.unlocked, model.walletID == wallet.id, model.chainID == chainID else { return }
                preview = result
                maxFee = Ethereum.formatUnits(result.transaction.maxFee, decimals: 9, precision: 9)
                priorityFee = Ethereum.formatUnits(result.transaction.maxPriorityFee, decimals: 9, precision: 9)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func reprice(_ current: TransactionPreview) {
        busy = true; error = nil; password = ""
        let client = model.client(), operation = model.epoch
        Task {
            defer { busy = false }
            do {
                let result = try await client.reprice(current, maxFeeGwei: maxFee, priorityFeeGwei: priorityFee)
                guard model.epoch == operation, model.unlocked else { return }; preview = result
            } catch { self.error = error.localizedDescription }
        }
    }
    private func send(_ preview: TransactionPreview) {
        busy = true; error = nil
        Task {
            defer { busy = false; password = "" }
            do { sentHash = try await model.send(preview: preview, password: password) }
            catch { self.error = error.localizedDescription; self.preview = nil }
        }
    }
}
