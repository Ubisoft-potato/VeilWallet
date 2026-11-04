import SwiftUI
import WalletCore
import BigInt

struct ContractCallView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var contract = ""
    @ViewState private var signature = "balanceOf(address)"
    @ViewState private var arguments = "[]"
    @ViewState private var value = "0"
    @ViewState private var result: String?
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var preview: TransactionPreview?
    var body: some View {
        SheetFrame(title: L("message.evm_contract_call"), subtitle: model.chain.name + L("message.arguments_encoded_locally_reads_and_simulation_use_tor")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    FieldLabel(title: L("message.contract_address")) { TextField(L("placeholder.evm_address"), text: $contract).disabled(busy) }
                    FieldLabel(title: L("message.canonical_function_signature")) { TextField(L("placeholder.contract_function"), text: $signature).disabled(busy) }
                    FieldLabel(title: L("message.arguments_json_string_array_integers_use_base_units")) { TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 90).disabled(busy) }
                    Text(L("message.supports_address_int_uint8_256_bool_bytes_string_dynamic_arrays"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    FieldLabel(title: L("message.attached_native_asset_93ac1172") + model.chain.symbol) { TextField("0", text: $value).disabled(busy) }
                    if let result { Text(L("message.return_data") + result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    ErrorText(text: error)
                    HStack {
                        Button(L("message.read_only_call")) { execute(write: false) }.disabled(busy || !model.ready)
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button(L("message.simulate_and_preview_transaction")) { execute(write: true) }.buttonStyle(PrimaryButton()).disabled(busy || !model.ready || model.wallet?.canSign != true || !model.chain.canTransfer)
                    }
                }
            }.frame(height: 430)
        }.sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview { EVMReviewView(preview: preview).environmentObject(model) }
        }
    }
    private func execute(write: Bool) {
        busy = true; error = nil; result = nil
        let rpc = model.client(); let selected = model.chainID; let wallet = model.walletID; let sender = model.address
        Task {
            defer { busy = false }
            do {
                guard let bytes = arguments.data(using: .utf8) else { throw WalletError.invalid(L("message.arguments_must_be_a_json_string_array")) }
                let values = try JSONDecoder().decode([String].self, from: bytes)
                let call = try ContractInvocation(contract: contract, signature: signature, arguments: values, nativeValue: Ethereum.parseUnits(value, decimals: rpc.chain.decimals))
                if write {
                    guard let sender else { throw WalletError.invalid(L("message.select_a_signing_account")) }
                    let prepared = try await rpc.prepareContract(sender: sender, invocation: call)
                    guard model.ready, model.chainID == selected, model.walletID == wallet else { return }; preview = prepared
                } else {
                    let bytes = try await rpc.readContract(call, sender: sender)
                    guard model.ready, model.chainID == selected, model.walletID == wallet else { return }; result = "0x" + bytes.hexString
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct DexSwapView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var inputID = "native"
    @ViewState private var outputID = ""
    @ViewState private var amount = ""
    @ViewState private var slippage = "50"
    @ViewState private var venueID = ""
    @ViewState private var fee = "0"
    @ViewState private var stable = false
    @ViewState private var viaWrapped = false
    @ViewState private var poolID = ""
    @ViewState private var quote: DexQuote?
    @ViewState private var approvalRequirement: DexApprovalRequirement = .none
    @ViewState private var submission: DexSubmission?
    @ViewState private var progress: String?
    @ViewState private var approvalStopped = false
    @ViewState private var preview: TransactionPreview?
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var operation: Task<Void, Never>?
    init() {}
    #if DEBUG
    init(previewApprovalHash: String) {
        _inputID = ViewState(initialValue: TokenCatalog.all.first { $0.chainID == 56 && $0.symbol == "USDT" }!.id)
        _outputID = ViewState(initialValue: "native"); _amount = ViewState(initialValue: "1")
        _venueID = ViewState(initialValue: "pancake-v3-56")
        _submission = ViewState(initialValue: DexSubmission(hash: previewApprovalHash, isApproval: true, title: DexApprovalRequirement.token.title))
    }
    #endif
    var body: some View {
        SheetFrame(title: L("message.dex_swap"), subtitle: model.chain.name + L("message.local_encoding_on_chain_quotes_through_tor")) {
            ScrollView { swapContent }.frame(height: 570)
        }.onAppear { if outputID.isEmpty { outputID = model.tokens.first?.id ?? "native" }; if venueID.isEmpty { venueID = DexCatalog.on(model.chainID).first?.id ?? "" } }
            .onChange(of: inputID) { _, _ in quote = nil }.onChange(of: outputID) { _, _ in quote = nil }
            .onChange(of: amount) { _, _ in quote = nil }.onChange(of: slippage) { _, _ in quote = nil }
            .onChange(of: venueID) { _, _ in quote = nil; fee = "0"; viaWrapped = false; stable = false; poolID = "" }
            .onChange(of: fee) { _, _ in quote = nil }.onChange(of: stable) { _, _ in quote = nil }.onChange(of: viaWrapped) { _, _ in quote = nil }.onChange(of: poolID) { _, _ in quote = nil }
            .onChange(of: model.walletID) { _, _ in resetSession() }
            .onChange(of: model.chainID) { _, _ in resetSession() }
            .onChange(of: model.profileID) { _, _ in resetSession() }
            .onDisappear { operation?.cancel() }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview {
                    let isApproval = !preview.purpose.isSwap
                    let title = isApproval ? approvalRequirement.title : L("message.dex_swap")
                    EVMReviewView(preview: preview, reviewTitle: title,
                                  submissionNotice: isApproval ? L("message.this_transaction_only_changes_approval_the_swap_has_not_been_6335180a") : L("message.the_swap_transaction_is_saved_verify_its_on_chain_receipt"),
                                  returnTitle: isApproval ? L("message.return_to_swap_verify_approval_and_continue") : L("message.return_to_swap")) { hash in
                        submission = DexSubmission(hash: hash, isApproval: isApproval, title: title)
                        quote = nil; progress = nil; approvalStopped = false
                    }.environmentObject(model)
                }
            }
    }
    private var swapContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if submission == nil { swapForm }
            if let submission { submissionPanel(submission) }
            if let progress { Text(LS(progress)).font(.system(size: 12)).foregroundStyle(.secondary) }
            if let quote { quotePanel(quote) }
            ErrorText(text: error)
            swapActions
        }
    }
    @ViewBuilder private var swapForm: some View {
        Picker(L("message.dex_protocol_version"), selection: $venueID) { ForEach(DexCatalog.on(model.chainID)) { venue in Text(LK(venue.name)).tag(venue.id) } }.disabled(formLocked)
        Picker(L("message.pay_asset"), selection: $inputID) { assets }.disabled(formLocked)
        Picker(L("message.receive_asset"), selection: $outputID) { assets }.disabled(formLocked)
        if model.tokens.isEmpty { Text(L("message.add_an_erc_20_in_assets_using_its_correct_network")).font(.system(size: 12)).foregroundStyle(.orange) }
        FieldLabel(title: L("message.amount_to_pay")) { TextField("0.00", text: $amount).disabled(formLocked) }
        FieldLabel(title: L("message.slippage_limit_basis_points_50_0_5_maximum_1000")) { TextField("50", text: $slippage).disabled(formLocked) }
        if let venue = DexCatalog.find(venueID) {
            if venue.usesFee { FieldLabel(title: venue.feeLabel + L("message.0_compare_common_tiers")) { TextField("0", text: $fee).disabled(formLocked) } }
            if venue.protocol == .solidly { Toggle(L("message.stable_asset_curve_pool"), isOn: $stable).disabled(formLocked) }
            if venue.usesPoolID { FieldLabel(title: L("message.balancer_pool_contract_address_verify_with_a_trusted_source")) { TextField(L("placeholder.evm_address"), text: $poolID).disabled(formLocked) } }
            if [.v2, .v2Avax, .v3, .v3Router02, .algebra, .solidly, .slipstream].contains(venue.protocol) { Toggle(L("message.route_through_the_wrapped_native_asset_two_hops"), isOn: $viaWrapped).disabled(formLocked) }
            if [.curve, .curveETH].contains(venue.protocol) { Text(L("message.this_curve_pool_has_no_on_chain_deadline_the_90")).font(.system(size: 11)).foregroundStyle(.orange) }
            if venue.usesPermit2 { Text(L("message.permit2_uses_two_approvals_an_exact_token_allowance_then_a")).font(.system(size: 11)).foregroundStyle(.orange) }
        }
        Text(L("message.quotes_cover_the_selected_protocol_and_route_not_the_whole"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private func submissionPanel(_ submission: DexSubmission) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text(submission.isApproval ? L("message.approval_in_progress_swap_not_sent") : L("message.swap_transaction_saved")).font(.headline)
                Text(submissionSummary)
                    .font(.system(size: 12))
                ReviewDetail(submission.title + L("message.local_hash"), submission.hash)
                Text(model.transactionStatus(hash: submission.hash)).font(.system(size: 12))
                Text(submission.isApproval ? L("message.after_approval_confirmation_is_verified_a_fresh_quote_opens_the") : L("message.verify_the_receipt_and_final_amount_in_transactions_submission_does"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(L("message.open_transactions")) { model.route = .activity; model.sheet = nil }
            }
        }
    }
    private func quotePanel(_ quote: DexQuote) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("message.estimated_output") + outputAmount(quote.amountOut, quote: quote))
                Text("\(LK(quote.venueName)) · \(quote.path.count - 1)\(L("message.hops"))").font(.system(size: 12))
                if DexCatalog.find(quote.venueID ?? "")?.usesFee == true { Text(L("message.selected_pool_parameter") + String(quote.fee)).font(.system(size: 11)) }
                Text(L("message.minimum_output_de27b13e") + outputAmount(quote.minimumOut, quote: quote)).foregroundStyle(Color.veilGreen)
                Text(L("field.router") + quote.invocation.contract).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Text(L("message.quotes_expire_after_90_seconds_the_on_chain_deadline_is"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(approvalRequirement.detail).font(.system(size: 11)).foregroundStyle(approvalRequirement == .none ? Color.veilGreen : .orange)
            }
        }
    }
    private var swapActions: some View {
        HStack {
            if let submission {
                if !submission.isApproval || approvalStopped {
                    Button(submission.isApproval ? L("message.end_this_flow") : L("message.start_a_new_swap")) { self.submission = nil; quote = nil; progress = nil; approvalStopped = false }
                        .disabled(busy)
                }
            } else {
                Button(L("message.get_a_fresh_quote")) { perform(stage: .quote) }.disabled(busy || !model.ready || model.tokens.isEmpty)
            }
            Spacer()
            if busy { Button(L("message.cancel_request")) { operation?.cancel() }; ProgressView().controlSize(.small) }
            if submission?.isApproval == true && !approvalStopped {
                Button(L("message.verify_approval_and_continue_swap")) { perform(stage: .continueApproval) }
                    .buttonStyle(PrimaryButton()).disabled(busy || !model.ready || model.wallet?.canSign != true)
            } else if submission == nil {
                Button(approvalRequirement == .none ? L("message.simulate_and_preview_swap") : L("message.preview") + approvalRequirement.title) { perform(stage: .preview) }
                    .buttonStyle(PrimaryButton()).disabled(busy || !model.ready || quote == nil || model.wallet?.canSign != true)
            }
        }
    }
    private var submissionSummary: String {
        let venue = DexCatalog.find(venueID)?.name ?? venueID
        let input = model.tokens.first { $0.id == inputID }?.symbol ?? model.chain.symbol
        let output = model.tokens.first { $0.id == outputID }?.symbol ?? model.chain.symbol
        return "\(venue) · \(amount) \(input) → \(output)"
    }
    private struct DexSubmission { let hash: String; let isApproval: Bool; let title: String }
    private enum Stage { case quote, preview, continueApproval }
    private var formLocked: Bool { busy || submission != nil }
    private func resetSession() { operation?.cancel(); quote = nil; preview = nil; submission = nil; progress = nil; approvalStopped = false }
    @ViewBuilder private var assets: some View {
        Text(model.chain.symbol + L("message.native_asset")).tag("native")
        ForEach(model.tokens) { token in Text(token.symbol + " · " + token.contract.prefix(10)).tag(token.id) }
    }
    private func outputAmount(_ value: BigUInt, quote: DexQuote) -> String {
        Ethereum.formatUnits(value, decimals: quote.output?.decimals ?? model.chain.decimals, precision: quote.output?.decimals ?? model.chain.decimals) + " " + (quote.output?.symbol ?? model.chain.symbol)
    }
    private func perform(stage: Stage) {
        busy = true; error = nil
        let rpc = model.client(); let session = model.epoch; let sender = model.address, walletID = model.walletID, chainID = model.chainID
        let isCurrentSelection = { model.epoch == session && model.walletID == walletID && model.chainID == chainID && model.address == sender }
        let input = model.tokens.first { $0.id == inputID }; let output = model.tokens.first { $0.id == outputID }
        let amount = amount, slippage = slippage, fee = fee, venueID = venueID, stable = stable, viaWrapped = viaWrapped, poolID = poolID
        let validAssets = (inputID == "native" || input != nil) && (outputID == "native" || output != nil)
        operation = Task {
            defer { busy = false }
            do {
                guard let sender, validAssets, let bps = UInt32(slippage), let rate = UInt32(fee), DexCatalog.find(venueID) != nil else { throw WalletError.invalid(L("message.invalid_account_asset_dex_or_fee_parameters")) }
                let dex = DexClient(rpc: rpc)
                if stage == .continueApproval {
                    guard let submission, submission.isApproval else { return }
                    let result = try await model.checkDexApproval(hash: submission.hash)
                    guard !Task.isCancelled, model.ready, isCurrentSelection() else { return }
                    switch result {
                    case .waiting(let message): progress = message; return
                    case .stopped(let message): progress = message; approvalStopped = true; return
                    case .ready: progress = L("message.approval_confirmed_updating_the_quote_the_swap_still_requires_a")
                    }
                }
                if stage != .preview {
                    let current = try await dex.quote(sender: sender, input: input, output: output, amount: amount, slippageBPS: bps, venueID: venueID, fee: rate, stable: stable, viaWrapped: viaWrapped, poolID: poolID.isEmpty ? nil : poolID)
                    if stage == .quote, let pending = try await model.pendingDexApproval(for: current) {
                        guard !Task.isCancelled, model.ready, isCurrentSelection() else { return }
                        submission = DexSubmission(hash: pending.hash, isApproval: true, title: pending.title)
                        quote = nil; progress = L("message.an_earlier_approval_is_still_unverified_verify_it_before_continuing"); return
                    }
                    let needed = try await dex.approvalRequirement(current, sender: sender)
                    guard !Task.isCancelled, model.ready, isCurrentSelection() else { return }
                    quote = current; approvalRequirement = needed
                    if stage == .quote { progress = nil; return }
                    submission = nil; progress = needed == .none ? L("message.approval_confirmed_and_quote_updated_review_the_swap_preview_and") : needed.detail
                }
                if let quote {
                    let current = try await approvalRequirement != .none ? dex.prepareApproval(quote, sender: sender) : dex.prepareSwap(quote, sender: sender)
                    guard !Task.isCancelled, model.ready, isCurrentSelection() else { return }
                    if !current.purpose.isSwap, let call = current.purpose.invocation {
                        approvalRequirement = call.signature == "approve(address,address,uint160,uint48)" ? .permit2 : (call.arguments.last == "0" ? .reset : .token)
                    }
                    preview = current
                }
            } catch { if !Task.isCancelled, isCurrentSelection() { self.error = error.localizedDescription } }
        }
    }
}

struct EVMReviewView: View {
    @ViewState private var preview: TransactionPreview
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let reviewTitle: String?
    private let submissionNotice: String?
    private let returnTitle: String?
    private let onSubmitted: ((String) -> Void)?
    @ViewState private var password = ""
    @ViewState private var error: String?
    @ViewState private var hash: String?
    @ViewState private var busy = false
    @ViewState private var maxFee = ""
    @ViewState private var tip = ""
    @ViewState private var replacementAccepted = false
    init(preview: TransactionPreview, reviewTitle: String? = nil, submissionNotice: String? = nil, returnTitle: String? = nil, onSubmitted: ((String) -> Void)? = nil) {
        _preview = ViewState(initialValue: preview); self.reviewTitle = reviewTitle; self.submissionNotice = submissionNotice; self.returnTitle = returnTitle; self.onSubmitted = onSubmitted
    }
    #if DEBUG
    init(submittedApproval preview: TransactionPreview, hash: String) {
        _preview = ViewState(initialValue: preview); _hash = ViewState(initialValue: hash)
        reviewTitle = DexApprovalRequirement.token.title
        submissionNotice = L("message.this_transaction_only_changes_approval_the_swap_has_not_been_6335180a")
        returnTitle = L("message.return_to_swap_verify_approval_and_continue"); onSubmitted = nil
    }
    #endif
    var body: some View {
        SheetFrame(title: preview.replacement?.action.label ?? reviewTitle ?? preview.purpose.title, subtitle: model.chain.name + L("message.resimulated_and_revalidated_before_local_signing_and_tor_broadcast")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ErrorText(text: error)
                    if let hash {
                        Panel(padding: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                ReviewDetail(L("message.local_transaction_hash"), hash)
                                Text(model.transactionStatus(hash: hash)).foregroundStyle(.secondary)
                                if let submissionNotice { Text(LS(submissionNotice)).font(.system(size: 12)).foregroundStyle(.orange) }
                                if let returnTitle { Button(returnTitle) { dismiss() }.buttonStyle(PrimaryButton()) }
                            }
                        }
                    }
                    ReviewDetail(L("message.signing_account"), preview.sender)
                    if preview.purpose.invocation == nil {
                        ReviewDetail(L("message.receiving_address"), preview.recipient)
                        if let token = preview.token { ReviewDetail(L("message.token_contract"), token.contract) }
                    }
                    if let reference = preview.replacement {
                        if !reference.hash.isEmpty { ReviewDetail(L("message.transaction_being_replaced"), reference.hash) }
                        Text(reference.action == .nonceRepair ? L("message.this_sends_zero_to_yourself_at_a_missing_nonce_and") : L("message.at_most_one_transaction_per_nonce_is_executed_on_the"))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    if let call = preview.purpose.invocation {
                        ReviewDetail(L("message.target_contract"), call.contract); ReviewDetail(L("message.function"), call.signature)
                        ForEach(Array(zip((try? ContractABI.types(call.signature)) ?? [], call.arguments).enumerated()), id: \.offset) { item in ReviewDetail(L("message.argument_0_1", item.offset + 1, item.element.0), item.element.1) }
                        if call.signature == "approve(address,uint256)" { Text(L("message.approval_allows_this_spender_to_spend_tokens_from_the_current")).font(.system(size: 11)).foregroundStyle(.orange) }
                        if call.signature == "approve(address,uint256)", call.arguments[1] == String((BigUInt(1) << 256) - 1) { Text(L("message.this_call_requests_an_unlimited_allowance")).foregroundStyle(.orange) }
                    }
                    if case .swap(let quote) = preview.purpose {
                        ReviewDetail(L("message.dex_route"), LK(quote.venueName) + " · " + quote.path.joined(separator: " → "))
                        ReviewDetail(L("message.pay"), Ethereum.formatUnits(quote.amountIn, decimals: quote.input?.decimals ?? model.chain.decimals, precision: 18) + " " + (quote.input?.symbol ?? model.chain.symbol))
                        ReviewDetail(L("message.minimum_output"), Ethereum.formatUnits(quote.minimumOut, decimals: quote.output?.decimals ?? model.chain.decimals, precision: 18) + " " + (quote.output?.symbol ?? model.chain.symbol))
                        ReviewDetail(L("message.receiving_account"), preview.sender)
                    }
                    if case .bridge(let quote, _) = preview.purpose { BridgeQuoteDetails(quote: quote) }
                    if case .privacy(let intent, _) = preview.purpose {
                        ReviewDetail(L("message.privacy_pool_note_id"), (PrivacyPoolCatalog.find(intent.poolID)?.name ?? intent.poolID) + " · " + intent.noteID.uuidString)
                        ReviewDetail(L("message.receiving_gas_paying_account"), intent.recipient)
                        Text(intent.kind == .deposit ? L("message.confirm_that_the_complete_note_is_backed_up_offline_before") : L("message.this_is_a_direct_withdrawal_the_current_account_pays_gas")).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    ReviewDetail(L("message.attached_native_asset"), preview.amount + " " + preview.symbol)
                    ReviewDetail(L("field.chain_id_nonce"), "\(preview.transaction.chainID) / \(preview.transaction.nonce)")
                    ReviewDetail(L("message.gas_limit"), String(preview.transaction.gasLimit))
                    ReviewDetail(L("message.maximum_priority_fee_gwei_1dad632d"), Ethereum.formatUnits(preview.transaction.maxFee, decimals: 9, precision: 9) + " / " + Ethereum.formatUnits(preview.transaction.maxPriorityFee, decimals: 9, precision: 9))
                    ReviewDetail(L("message.maximum_execution_fee"), formattedFee(preview.transaction.maximumFee))
                    ReviewDetail(L("message.estimated_l1_data_operator_fee"), formattedFee(preview.additionalFees.l1DataFee) + " / " + formattedFee(preview.additionalFees.operatorFee))
                    ReviewDetail(L("message.total_fee_budget"), formattedFee(preview.totalFeeBudget))
                    Text(L("message.node_simulation_checks_whether_this_call_reverts_it_does_not")).font(.system(size: 11)).foregroundStyle(.orange)
                    if hash == nil {
                        DisclosureGroup(L("message.custom_fees_preserve_nonce_and_transaction_intent")) {
                            VStack(alignment: .leading, spacing: 10) {
                                FieldLabel(title: L("message.maximum_fee_legacy_gas_price_gwei")) { TextField(L("unit.gwei"), text: $maxFee) }
                                if preview.transaction.mode == .eip1559 { FieldLabel(title: L("message.maximum_priority_fee_gwei")) { TextField(L("unit.gwei"), text: $tip) } }
                                Button(L("message.recalculate_and_update_fee_preview")) {
                                    busy = true; error = nil
                                    Task { defer { busy = false }; do { preview = try await model.client().reprice(preview, maxFeeGwei: maxFee, priorityFeeGwei: tip); replacementAccepted = false } catch { self.error = error.localizedDescription } }
                                }.disabled(busy || !model.ready || maxFee.isEmpty)
                            }.padding(.top, 10)
                        }
                        if preview.replacement != nil { Toggle(L("message.i_reviewed_the_replacement_and_its_increased_fee_budget"), isOn: $replacementAccepted) }
                        FieldLabel(title: L("message.vault_password_verify_again_for_each_signature")) { SecureField(L("message.enter_password"), text: $password) }
                        Button(busy ? L("message.signing_and_broadcasting") : L("message.confirm_sign_and_send")) {
                            busy = true; error = nil
                            let operation = model.epoch, walletID = model.walletID, started = Date(), reviewed = preview
                            let isCurrentSelection = { operation == model.epoch && walletID == model.walletID && model.chainID == reviewed.transaction.chainID && model.address == reviewed.sender }
                            Task {
                                defer { busy = false; password = "" }
                                do {
                                    let result = try await model.send(preview: reviewed, password: password)
                                    guard isCurrentSelection() else { return }; hash = result; onSubmitted?(result)
                                } catch {
                                    guard isCurrentSelection() else { return }
                                    self.error = error.localizedDescription
                                    if let walletID {
                                        do {
                                            if let saved = try await model.savedTransactionHash(matching: reviewed, walletID: walletID, since: started, operation: operation) {
                                                hash = saved; onSubmitted?(saved)
                                                self.error = L("message.the_signed_transaction_is_saved_submission_remains_unverified_look_up") + error.localizedDescription
                                            }
                                        } catch { self.error = L("message.the_local_transaction_archive_could_not_be_verified_check_existing") }
                                    }
                                }
                            }
                        }.buttonStyle(PrimaryButton()).disabled(busy || password.isEmpty || !model.ready || preview.isExpired || (preview.replacement != nil && !replacementAccepted))
                    }
                }
            }.frame(height: 600)
        }.onAppear { maxFee = Ethereum.formatUnits(preview.transaction.maxFee, decimals: 9, precision: 9); tip = Ethereum.formatUnits(preview.transaction.maxPriorityFee, decimals: 9, precision: 9) }.onDisappear { password = "" }
    }
    private func formattedFee(_ value: BigUInt) -> String { Ethereum.formatUnits(value, decimals: model.chain.decimals, precision: model.chain.decimals) + " " + model.chain.symbol }
}
struct ReviewDetail: View {
    let title: String; let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
