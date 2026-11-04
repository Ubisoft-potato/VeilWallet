import SwiftUI
import WalletCore
import BigInt

struct TronDexSwapView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var mode = TronDexMode.smart
    @ViewState private var inputID = "native"
    @ViewState private var outputID = ""
    @ViewState private var amount = ""
    @ViewState private var slippage = "50"
    @ViewState private var quote: TronDexQuote?
    @ViewState private var approvalRequirement: DexApprovalRequirement = .none
    @ViewState private var submission: Submission?
    @ViewState private var progress: String?
    @ViewState private var stopped = false
    @ViewState private var requestID = UUID()
    @ViewState private var plan: NativeTransferPlan?
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var operation: Task<Void, Never>?
    private var assets: [Token] {
        let presets = [("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "USDT", 6), (TronDexClient.wrapped, "WTRX", 6), ("TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz", "USDD", 18), ("TSSMHYeV2uE9qYH95DqyoCuNCzEL1NvU3S", "SUN", 18)].compactMap { try? Token(chainID: TronAddress.chainID, contract: $0.0, symbol: $0.1, decimals: $0.2) }
        return model.tokens + presets.filter { item in !model.tokens.contains { $0.id == item.id } }
    }
    var body: some View {
        SheetFrame(title: L("message.tron_dex_swap"), subtitle: L("message.sunswap_sun_local_encoding_and_signing_all_requests_use_bundled")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(L("message.swap_mode"), selection: $mode) { ForEach(TronDexMode.allCases, id: \.self) { Text($0.name).tag($0) } }.disabled(formLocked)
                    Picker(L("message.pay_asset"), selection: $inputID) { choices }.disabled(formLocked)
                    Picker(L("message.receive_asset"), selection: $outputID) { choices }.disabled(formLocked)
                    FieldLabel(title: L("message.amount_to_pay")) { TextField("0.00", text: $amount).disabled(formLocked) }
                    FieldLabel(title: L("message.slippage_basis_points_50_0_5_maximum_1000")) { TextField("50", text: $slippage).disabled(formLocked) }
                    if mode == .smart {
                        Text(L("message.sun_s_official_service_supplies_candidate_routes_using_only_the"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(L("message.trc20_may_require_separate_confirmations_exact_token_allowance_short_lived")).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Text(L("message.common_asset_addresses_come_from_the_local_catalog_decimals_are")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let quote {
                        Panel(padding: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("message.estimated_output") + outputAmount(quote.amountOut, quote: quote))
                                Text(L("message.minimum_received_7e1529eb") + outputAmount(quote.minimumOut, quote: quote)).foregroundStyle(Color.veilGreen)
                                Text(L("message.route_43808135") + quote.hops.map(\.version).joined(separator: " → ")).font(.system(size: 11))
                                Text(L("field.router") + quote.invocation.contract).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                Text(L("message.quotes_expire_after_90_seconds_verify_approval_confirmation_and_continue")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let submission {
                        Panel(padding: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(submission.isApproval ? L("message.approval_saved_swap_not_sent") : L("message.swap_transaction_saved")).font(.headline)
                                Text(submission.hash).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                Text(model.transactionStatus(hash: submission.hash)).font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(L("message.verify_queued_or_timed_out_transactions_in_transactions_before_signing")).font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    } else if quote != nil {
                        Text(approvalRequirement.detail).font(.system(size: 11)).foregroundStyle(approvalRequirement == .none ? Color.veilGreen : .orange)
                    }
                    if let progress { Text(LS(progress)).font(.system(size: 12)).foregroundStyle(.secondary) }
                    ErrorText(text: error)
                    HStack {
                        if submission == nil {
                            Button(L("message.get_a_fresh_quote")) { perform(.quote) }.disabled(busy || !model.ready)
                        } else {
                            Button(L("message.start_new_swap")) { resetSession() }.disabled(busy)
                        }
                        Spacer()
                        if busy { Button(L("message.cancel_request")) { operation?.cancel() }; ProgressView().controlSize(.small) }
                        if let submission, submission.isApproval {
                            Button(L("message.verify_approval_and_continue_swap")) { perform(.continueApproval) }.buttonStyle(PrimaryButton()).disabled(busy || stopped || !model.ready)
                        } else if submission == nil {
                            Button(approvalRequirement == .none ? L("message.simulate_and_preview_swap") : L("message.preview") + approvalRequirement.title) { perform(.preview) }
                                .buttonStyle(PrimaryButton()).disabled(busy || !model.ready || quote == nil || model.wallet?.canSign != true)
                        }
                    }
                }
            }.frame(height: 560)
        }.onAppear { outputID = assets.first?.id ?? "native" }
            .onChange(of: inputID) { _, _ in quote = nil }.onChange(of: outputID) { _, _ in quote = nil }
            .onChange(of: amount) { _, _ in quote = nil }.onChange(of: slippage) { _, _ in quote = nil }.onChange(of: mode) { _, _ in quote = nil }
            .onChange(of: model.walletID) { _, _ in resetSession() }
            .onChange(of: model.chainID) { _, _ in resetSession() }
            .onChange(of: model.profileID) { _, _ in resetSession() }
            .onDisappear { operation?.cancel() }
            .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
                if let plan {
                    let approval = plan.swap == nil
                    TronTransactionReviewView(plan: plan, submissionNotice: approval ? L("message.this_transaction_only_changes_approval_the_swap_has_not_been") : L("message.the_swap_is_saved_verify_its_solidified_receipt_and_actual"), returnTitle: approval ? L("message.return_to_swap_verify_approval_and_continue") : L("message.return_to_swap")) { hash in
                        submission = Submission(hash: hash, isApproval: approval)
                        quote = nil; stopped = false
                    }.environmentObject(model)
                }
            }
    }
    private struct Submission { let hash: String; let isApproval: Bool }
    private enum Stage { case quote, preview, continueApproval }
    private var formLocked: Bool { busy || submission != nil }
    private func resetSession() { operation?.cancel(); requestID = UUID(); busy = false; quote = nil; plan = nil; submission = nil; progress = nil; stopped = false; error = nil }
    @ViewBuilder private var choices: some View {
        Text(L("message.trx_native_asset")).tag("native")
        ForEach(assets) { token in Text(token.symbol + " · " + token.contract.prefix(9)).tag(token.id) }
    }
    private func outputAmount(_ value: BigUInt, quote: TronDexQuote) -> String {
        Ethereum.formatUnits(value, decimals: quote.output?.decimals ?? 6, precision: quote.output?.decimals ?? 6) + " " + (quote.output?.symbol ?? "TRX")
    }
    private func perform(_ stage: Stage) {
        busy = true; error = nil
        let id = UUID(); requestID = id
        let walletID = model.walletID, chainID = model.chainID, profileID = model.profileID, session = model.epoch, sender = model.address
        let isCurrent = { model.epoch == session && model.walletID == walletID && model.chainID == chainID && model.profileID == profileID && model.address == sender }
        let input = assets.first { $0.id == inputID }, output = assets.first { $0.id == outputID }
        let validAssets = (inputID == "native" || input != nil) && (outputID == "native" || output != nil)
        let amount = amount, slippage = slippage, mode = mode
        let dex = TronDexClient(client: TronContractClient(transport: TorTransport(gate: model.gate), chain: model.chain, isolation: model.isolationKey))
        operation = Task {
            defer { if requestID == id { busy = false } }
            do {
                guard let sender, validAssets, let bps = UInt32(slippage) else { throw WalletError.invalid(L("message.invalid_tron_signing_account_asset_or_slippage")) }
                if stage == .continueApproval {
                    guard let submission, submission.isApproval else { return }
                    let result = try await model.checkTronDexApproval(hash: submission.hash)
                    guard !Task.isCancelled, model.ready, isCurrent() else { return }
                    switch result {
                    case .waiting(let message): progress = message; return
                    case .stopped(let message): progress = message; stopped = true; return
                    case .ready: progress = L("message.approval_solidified_successfully_getting_a_fresh_quote")
                    }
                }
                if stage != .preview {
                    let current = try await dex.quote(sender: sender, input: input, output: output, amount: amount, slippageBPS: bps, mode: mode)
                    if stage == .quote, let pending = try await model.pendingTronDexApproval(for: current) {
                        guard !Task.isCancelled, model.ready, isCurrent() else { return }
                        submission = Submission(hash: pending.hash, isApproval: true); quote = nil
                        progress = pending.title + L("message.is_unverified_verify_the_original_transaction_to_avoid_duplicate_approval"); return
                    }
                    let needed = try await dex.approvalRequirement(current, sender: sender)
                    guard !Task.isCancelled, model.ready, isCurrent() else { return }
                    quote = current; approvalRequirement = needed
                    if stage == .quote { progress = nil; return }
                    submission = nil; progress = needed == .none ? L("message.allowance_verified_the_next_transaction_is_the_swap_review_it") : needed.detail
                }
                if let quote {
                    let current = try await (approvalRequirement == .none ? dex.prepareSwap(quote, sender: sender) : dex.prepareApproval(quote, sender: sender))
                    guard !Task.isCancelled, model.ready, isCurrent() else { return }
                    if let call = current.contract, current.swap == nil {
                        approvalRequirement = call.signature == "approve(address,address,uint160,uint48)" ? .permit2 : (call.arguments.last == "0" ? .reset : .token)
                    }
                    plan = current
                }
            } catch { if !Task.isCancelled, isCurrent() { self.error = error.localizedDescription } }
        }
    }
}

struct TronTransactionReviewView: View {
    let plan: NativeTransferPlan
    let submissionNotice: String?
    let returnTitle: String?
    let onSubmitted: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    init(plan: NativeTransferPlan, submissionNotice: String? = nil, returnTitle: String? = nil, onSubmitted: ((String) -> Void)? = nil) {
        self.plan = plan; self.submissionNotice = submissionNotice; self.returnTitle = returnTitle; self.onSubmitted = onSubmitted
    }
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var hash: String?
    var body: some View {
        SheetFrame(title: plan.bridge != nil ? L("message.confirm_tron_bridge") : plan.swap == nil ? L("message.confirm_tron_approval") : L("message.confirm_tron_swap"), subtitle: L("message.resimulate_and_verify_the_password_before_local_signing_and_tor")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ReviewDetail(L("message.signing_account_recipient"), plan.sender)
                    ReviewDetail(L("message.target_contract"), plan.recipient)
                    if let quote = plan.bridge { BridgeQuoteDetails(quote: quote) }
                    if let quote = plan.swap {
                        ReviewDetail(L("message.pay"), Ethereum.formatUnits(quote.amountIn, decimals: quote.input?.decimals ?? 6, precision: 18) + " " + (quote.input?.symbol ?? "TRX"))
                        ReviewDetail(L("message.minimum_received"), Ethereum.formatUnits(quote.minimumOut, decimals: quote.output?.decimals ?? 6, precision: 18) + " " + (quote.output?.symbol ?? "TRX"))
                        ForEach(Array(quote.hops.enumerated()), id: \.offset) { step in ReviewDetail(L("message.route") + String(step.offset + 1) + " · " + step.element.version, step.element.from + " → " + step.element.to) }
                    }
                    if let call = plan.contract {
                        ReviewDetail(L("message.function"), call.signature)
                        if plan.swap == nil { ForEach(Array(call.arguments.enumerated()), id: \.offset) { item in ReviewDetail(L("message.argument") + String(item.offset + 1), item.element) } }
                    }
                    ReviewDetail(L("message.attached_trx"), Ethereum.formatUnits(plan.amount, decimals: 6, precision: 6))
                    ReviewDetail(L("message.total_fee_budget_trx"), Ethereum.formatUnits(plan.feeBudget, decimals: 6, precision: 6))
                    ForEach(plan.details, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if let hash {
                        ReviewDetail(L("message.local_transaction_hash"), hash)
                        Text(model.transactionStatus(hash: hash)).font(.system(size: 12)).foregroundStyle(.secondary)
                        if let submissionNotice { Text(LS(submissionNotice)).foregroundStyle(.orange) }
                        if let returnTitle { Button(returnTitle) { dismiss() }.buttonStyle(PrimaryButton()) }
                    }
                    else {
                        FieldLabel(title: L("message.vault_password_verify_again_for_every_step")) { SecureField(L("message.enter_password"), text: $password) }
                        ErrorText(text: error)
                        Button(busy ? L("message.signing_and_broadcasting") : L("message.confirm_sign_and_send")) {
                            busy = true; error = nil
                            let session = model.epoch, walletID = model.walletID, started = Date()
                            Task {
                                defer { busy = false; password = "" }
                                do {
                                    let result = try await model.sendNative(plan: plan, password: password)
                                    guard model.epoch == session, model.walletID == walletID, model.address == plan.sender, model.chainID == plan.chainID else { return }
                                    hash = result; onSubmitted?(result)
                                } catch {
                                    guard model.epoch == session, model.walletID == walletID else { return }
                                    if let walletID, let saved = try? await model.savedNativeTransactionHash(matching: plan, walletID: walletID, since: started, operation: session) {
                                        hash = saved; onSubmitted?(saved)
                                    } else { self.error = error.localizedDescription }
                                }
                            }
                        }.buttonStyle(PrimaryButton()).disabled(busy || password.isEmpty || !model.ready || plan.isExpired)
                    }
                }
            }.frame(height: 570)
        }.onDisappear { password = "" }
    }
}
