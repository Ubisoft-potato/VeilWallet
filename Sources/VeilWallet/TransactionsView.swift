import SwiftUI
import WalletCore
import BigInt

private struct TransactionGroup: Identifiable {
    let id: UUID
    let attempts: [Activity]
    var root: Activity { attempts.first! }
    var winner: Activity? { attempts.first { [.confirmed, .cancelled, .failed].contains($0.phase) } }
    var current: Activity { winner ?? attempts.last(where: { $0.phase != .discarded }) ?? root }
    var pending: Bool { winner == nil && attempts.contains { $0.isUnresolved } }
}
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var filter = 0
    @ViewState private var search = ""
    @ViewState private var polling = false
    @ViewState private var nonceInfo = ""
    @ViewState private var repair: TransactionPreview?
    private var groups: [TransactionGroup] {
        Dictionary(grouping: model.activities) { $0.transaction?.groupID ?? $0.id }.map { TransactionGroup(id: $0.key, attempts: $0.value.sorted { $0.date < $1.date }) }
            .filter { group in
                (filter == 2 || (filter == 0 ? group.pending : !group.pending)) && (search.isEmpty || group.attempts.contains { [$0.hash, $0.to, $0.amount, $0.symbol, $0.operation ?? "", $0.transaction?.sequence ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search) })
            }.sorted { $0.root.date > $1.root.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(eyebrow: L("section.transactions.eyebrow"), title: L("navigation.transactions"), subtitle: L("message.signed_transactions_and_queues_are_encrypted_locally_chain_queries_and"))
            HStack {
                Picker(L("message.scope"), selection: $filter) { Text(L("message.pending")).tag(0); Text(L("message.history")).tag(1); Text(L("message.all")).tag(2) }.pickerStyle(.segmented).frame(width: 260)
                TextField(L("message.search_hashes_recipients_amounts_or_nonces"), text: $search).textFieldStyle(.roundedBorder)
                Button(L("message.refresh_current_network")) { Task { await model.refreshTransactionQueue() } }.disabled(!model.ready)
            }
            HStack {
                Toggle(L("message.refresh_through_tor_every_30_seconds_while_viewing_this_page"), isOn: $polling).toggleStyle(.checkbox)
                Spacer()
                if model.chain.isEVM { Button(L("message.check_nonce_queue")) { inspectNonce() }.disabled(!model.ready || model.address == nil) }
            }.font(.system(size: 11))
            if !nonceInfo.isEmpty { Text(nonceInfo).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.veilAccent) }
            if model.chain.isEVM {
                Button(L("message.preview_a_local_nonce_gap_repair")) {
                    Task { do { guard let address = model.address else { throw WalletError.locked }; repair = try await model.client().prepareNonceRepair(sender: address) } catch { model.error = error.localizedDescription } }
                }.disabled(!model.ready || model.wallet?.canSign != true)
            }
            if groups.isEmpty { Panel { ContentUnavailableView(L("message.no_transactions_match_this_filter"), systemImage: "tray", description: Text(L("message.locally_initiated_transactions_replacements_and_broadcast_attempts_appear_here_there"))) } }
            ForEach(groups) { group in TransactionGroupView(group: group) }
            Text(L("message.each_refresh_checks_at_most_the_50_latest_records_for")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task(id: "\(polling)-\(model.chainID)-\(model.walletID?.uuidString ?? "")") {
            guard polling else { return }
            while !Task.isCancelled, model.unlocked {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled, model.route == .activity else { return }
                if model.ready { await model.refreshTransactionQueue() }
            }
        }
        .sheet(isPresented: Binding(get: { repair != nil }, set: { if !$0 { repair = nil } })) { if let repair { EVMReviewView(preview: repair).environmentObject(model) } }
    }
    private func inspectNonce() {
        guard let sender = model.address else { return }
        let client = model.client(), policy = EVMNoncePolicy(activities: model.local.activities), chain = model.chainID
        Task {
            do {
                try await client.verifyChain(); let state = try await client.nonceState(sender: sender)
                let gap = try policy.gap(chainID: chain, sender: sender, latest: state.latest, pending: state.pending)
                guard model.unlocked, model.chainID == chain, model.address == sender else { return }
                nonceInfo = L("message.confirmed_next_nonce_0_node_pending_next_nonce_1", state.latest, state.pending) + (gap.map { L("message.local_gap_0", $0) } ?? L("message.no_local_gap_found"))
            } catch { model.error = error.localizedDescription }
        }
    }
}
private enum TransactionDialog: String, Identifiable { case replay, discard, rebuild, privacy; var id: String { rawValue } }
private struct TransactionGroupView: View {
    let group: TransactionGroup
    @EnvironmentObject private var model: AppModel
    @ViewState private var preview: TransactionPreview?
    @ViewState private var utxoPreview: UTXOManagementPreview?
    @ViewState private var dialog: TransactionDialog?
    @ViewState private var rate = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var details: TransactionArchive?
    @ViewState private var detailsExpanded = false
    private var current: Activity { group.current }
    private var statusIcon: String {
        if group.pending { return "clock" }
        if current.phase == .confirmed || current.status == WalletLocalization.legacy("receipt.confirmed") { return "checkmark.circle" }
        return current.phase == .failed || current.phase == .conflicted ? "exclamationmark.triangle" : "xmark.circle"
    }
    var body: some View {
        Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: statusIcon).foregroundStyle(Color.veilAccent)
                    Text(group.root.operation.map(LS) ?? L("message.send_0_1", group.root.amount, group.root.symbol)).font(.system(size: 16, weight: .medium))
                    Spacer(); Pill(text: current.statusLabel, color: current.phase == .confirmed ? .veilGreen : .orange)
                }
                ReviewDetail(L("message.original_payment_recipient"), group.root.to)
                if let record = current.transaction {
                    ReviewDetail(L("message.sender_sequence"), record.sender + (record.sequence.map { " · " + $0 } ?? ""))
                    let observation = record.observation
                    if let confirmations = observation.confirmations { Text(L("message.confirmations_0_local_threshold_1", confirmations, observation.requiredConfirmations ?? 0)).font(.system(size: 11)) }
                    if let fee = observation.executionFee, let amount = BigUInt(fee) { ReviewDetail(L("message.known_execution_fee_additional_fees_separate"), Ethereum.formatUnits(amount, decimals: model.chain.decimals, precision: model.chain.decimals) + " " + model.chain.symbol) }
                    if let detail = observation.detail { Text(LS(detail)).font(.system(size: 11)).foregroundStyle(.orange) }
                    Text(L("message.0_hashes_in_this_group_1_broadcast_attempts_for_this", group.attempts.count, record.broadcastAttempts)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(group.attempts) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text((item.transaction?.action.label ?? L("message.legacy_record")) + " · " + item.statusLabel).font(.system(size: 12, weight: .medium)); Spacer(); Text(walletDate(item.date, date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                                HStack(spacing: 12) {
                                    Text(item.hash).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                    ClipboardCopyButton(text: item.hash, title: L("message.copy_transaction_hash"), iconOnly: true)
                                }
                            }.padding(14).background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                } label: { Label(L("message.all_signed_hashes_and_statuses_0", group.attempts.count), systemImage: "number") }
                if current.transaction != nil {
                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        if let archive = details, archive.hash == current.hash { TransactionArchiveDetails(archive: archive) }
                        else if busy { ProgressView().controlSize(.small) }
                        else { Button(L("message.reload_local_transaction_parameters")) { loadDetails() } }
                    } label: { Label(L("message.approved_transaction_parameters"), systemImage: "doc.text.magnifyingglass") }
                        .onChange(of: detailsExpanded) { _, expanded in if expanded && details == nil && !busy { loadDetails() } }
                    HStack {
                        Button(L("message.check_the_whole_group_s_on_chain_status")) { Task { await model.checkReceipt(current) } }.disabled(!model.ready || busy)
                        Spacer()
                    }
                    managementActions
                } else {
                    HStack {
                        Button(L("message.query_receipt_through_tor")) { Task { await model.checkReceipt(current) } }.disabled(!model.ready)
                        if model.chain.isEVM { Button(L("message.verify_signature_and_adopt_legacy_record")) { run { try await model.adoptTransaction(current) } }.disabled(!model.ready || busy) }
                    }
                    if current.privacyNoteID != nil { PrivacyRetryView(activity: current) }
                }
                if let bridge = group.root.bridge, group.winner?.transaction?.action != .cancel {
                    BridgeActivityView(activity: group.root).id(bridge.sourceID + group.root.effectiveHash)
                }
                if group.root.privacyNoteID != nil, group.winner != nil { Button(L("message.reconcile_note_records_with_confirmed_results")) { dialog = .privacy }.disabled(!model.ready || busy) }
                if busy { ProgressView().controlSize(.small) }
                ErrorText(text: error)
            }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) { if let preview { EVMReviewView(preview: preview).environmentObject(model) } }
        .sheet(isPresented: Binding(get: { utxoPreview != nil }, set: { if !$0 { utxoPreview = nil } })) { if let utxoPreview { UTXOReviewView(preview: utxoPreview).environmentObject(model) } }
        .sheet(item: $dialog) { mode in TransactionActionView(activity: current, mode: mode).environmentObject(model) }
        .onChange(of: current.hash) { _, _ in details = nil; detailsExpanded = false }
    }
    @ViewBuilder private var managementActions: some View {
        if group.pending, let record = current.transaction {
            ActionFlow {
                Button(record.broadcastAttempts == 0 ? L("message.broadcast_local_queue_item") : L("message.rebroadcast_identical_signed_transaction")) { dialog = .replay }.disabled(!record.maySubmitAgain || !model.ready || busy || model.wallet?.canSign != true)
                if record.broadcastAttempts == 0, current.phase == .queued { Button(L("message.discard_local_queue_item")) { dialog = .discard }.disabled(!model.ready || busy) }
                if model.chain.isEVM, record.broadcastAttempts > 0 {
                    Button(record.action == .cancel ? L("message.speed_up_cancellation") : L("message.speed_up")) { evm(record.action == .cancel ? .cancel : .speedUp) }.disabled(!model.ready || busy || model.wallet?.canSign != true)
                    Button(L("message.request_cancellation")) { evm(.cancel) }.disabled(!model.ready || busy || model.wallet?.canSign != true)
                }
            }
            if [.bitcoin, .litecoin].contains(model.chain.family), record.broadcastAttempts > 0 {
                ActionFlow {
                    TextField(L("message.integer_base_units_vbyte"), text: $rate).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button(L("message.read_node_fee_rate")) { run { rate = String(try await model.nativeClient().suggestedUTXOFeeRate()) } }.disabled(!model.ready || busy)
                    Button(L("message.rbf_speed_up")) { utxo(record.action == .cancel ? .cancel : .speedUp) }.disabled(rate.isEmpty || !model.ready || busy)
                    Button(L("message.rbf_cancellation")) { utxo(.cancel) }.disabled(rate.isEmpty || !model.ready || busy)
                    Button(L("transaction.cpfp_abbreviation")) { utxo(.cpfp) }.disabled(rate.isEmpty || !model.ready || busy)
                }
            }
            if !model.chain.isEVM && ![.bitcoin, .litecoin].contains(model.chain.family) {
                Text(L("message.this_chain_has_no_evm_style_speed_up_or_cancellation")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        if [.failed, .cancelled, .expired, .discarded].contains(current.phase) { Button(L("message.verify_then_rebuild_requote")) { dialog = .rebuild }.disabled(!model.ready || busy) }
    }
    private func evm(_ action: TransactionAction) { run { preview = try await model.prepareReplacement(current, action: action) } }
    private func utxo(_ action: TransactionAction) { run { utxoPreview = try await model.prepareUTXOManagement(current, action: action, rate: rate) } }
    private func loadDetails() { run { details = try await model.store.transaction(id: current.id) } }
    private func run(_ body: @escaping @MainActor () async throws -> Void) { busy = true; error = nil; Task { defer { busy = false }; do { try await body() } catch { self.error = error.localizedDescription } } }
}
private struct TransactionArchiveDetails: View {
    let archive: TransactionArchive
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = archive.evm {
                ReviewDetail(L("message.target_native_amount_in_base_units"), p.transaction.to + " · " + String(p.transaction.value))
                ReviewDetail(L("message.nonce_gas_limit"), "\(p.transaction.nonce) / \(p.transaction.gasLimit)")
                ReviewDetail(L("message.fee_rate_gwei"), Ethereum.formatUnits(p.transaction.maxFee, decimals: 9, precision: 9) + L("message.priority_fee") + Ethereum.formatUnits(p.transaction.maxPriorityFee, decimals: 9, precision: 9))
                if let call = p.purpose.invocation { ReviewDetail(L("message.function"), call.signature); ForEach(Array(call.arguments.enumerated()), id: \.offset) { value in ReviewDetail(L("message.argument_0", value.offset + 1), value.element) } }
            } else if let p = archive.native { ReviewDetail(L("message.execution_target"), p.recipient); ReviewDetail(L("message.fee_budget_base_units"), String(p.feeBudget)); if let call = p.contract { ReviewDetail(L("message.function"), call.signature) } }
            else if let p = archive.monero { ReviewDetail(L("message.xmr_recipient"), p.recipient); ReviewDetail(L("message.fee_piconero"), String(p.fee)) }
            Text(L("message.only_approved_parameters_are_shown_signed_payloads_and_xmr_relay")).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).background(Color.veilAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
private struct TransactionActionView: View {
    let activity: Activity
    let mode: TransactionDialog
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password = ""
    @ViewState private var acknowledged = false
    @ViewState private var busy = false
    @ViewState private var result: String?
    @ViewState private var error: String?
    private var title: String { switch mode { case .replay: return L("message.rebroadcast_authorized_transaction"); case .discard: return L("message.discard_local_queue_item"); case .rebuild: return L("message.rebuild_transaction"); case .privacy: return L("message.reconcile_note_submission_record") } }
    var body: some View {
        SheetFrame(title: title, subtitle: L("message.actions_apply_only_to_this_account_and_network_no_automatic")) {
            VStack(alignment: .leading, spacing: 16) {
                ReviewDetail(L("message.transaction_hash"), activity.hash)
                Text(mode == .rebuild ? L("message.rebuilding_creates_a_new_signature_and_hash_expiry_plus_missing") : mode == .replay ? L("message.this_sends_only_the_identical_signed_transaction_saved_locally_preserving") : mode == .discard ? L("message.only_local_queue_items_with_no_broadcast_attempt_can_be") : L("message.recheck_the_canonical_receipt_and_confirmation_threshold_confirmed_cancellation_or"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if result == nil {
                    Toggle(L("message.i_verified_the_original_status_and_understand_this_action"), isOn: $acknowledged)
                    if mode != .rebuild { SecureField(L("message.vault_password"), text: $password).textFieldStyle(.roundedBorder) }
                    ErrorText(text: error)
                    Button(busy ? L("message.processing") : L("message.confirm") + title) { perform() }.buttonStyle(PrimaryButton()).disabled(busy || !acknowledged || !model.ready || (mode != .rebuild && password.isEmpty))
                } else { Text(result ?? "").foregroundStyle(Color.veilGreen); Button(L("message.done")) { dismiss() } }
            }
        }.onDisappear { password = "" }
    }
    private func perform() {
        busy = true; error = nil
        Task {
            defer { busy = false; password = "" }
            do {
                switch mode {
                case .replay: let hash = try await model.resubmit(activity, password: password); result = model.transactionStatus(hash: hash)
                case .discard: try await model.discardQueued(activity, password: password); result = L("message.the_local_queue_item_was_discarded_no_on_chain_cancellation")
                case .privacy: try await model.syncPrivacyOutcome(activity, password: password); result = L("message.submission_records_were_reconciled_the_note_was_retained")
                case .rebuild:
                    dismiss()
                    try await Task.sleep(for: .milliseconds(350))
                    do { try await model.rebuild(activity, acknowledged: acknowledged) } catch { model.error = error.localizedDescription }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
struct UTXOReviewView: View {
    let preview: UTXOManagementPreview
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var acknowledged = false
    @ViewState private var busy = false
    @ViewState private var hash: String?
    @ViewState private var error: String?
    var body: some View {
        SheetFrame(title: preview.action.label + " · " + model.chain.symbol, subtitle: L("message.inputs_signatures_and_fees_are_rechecked_before_local_signing_and")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ReviewDetail(L("message.original_transaction"), preview.original.hash)
                    ReviewDetail(L("message.recipient_for_this_transaction"), preview.plan.recipient)
                    ReviewDetail(L("message.output_amount_for_this_transaction"), Ethereum.formatUnits(preview.plan.amount, decimals: model.chain.decimals, precision: model.chain.decimals) + " " + model.chain.symbol)
                    ReviewDetail(L("message.fee"), Ethereum.formatUnits(preview.plan.feeBudget, decimals: model.chain.decimals, precision: model.chain.decimals) + " " + model.chain.symbol)
                    ForEach(preview.plan.details, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if let hash { ReviewDetail(L("message.local_hash_eb65ca9b"), hash); Text(model.transactionStatus(hash: hash)).foregroundStyle(Color.veilGreen) }
                    else {
                        Toggle(L("message.i_reviewed_the_fee_and_understand_that_the_original_may"), isOn: $acknowledged)
                        SecureField(L("message.vault_password"), text: $password).textFieldStyle(.roundedBorder)
                        ErrorText(text: error)
                        Button(L("message.sign_and_broadcast")) { busy = true; Task { defer { busy = false; password = "" }; do { hash = try await model.sendUTXOManagement(preview, password: password) } catch { self.error = error.localizedDescription } } }.buttonStyle(PrimaryButton()).disabled(busy || !acknowledged || password.isEmpty || !model.ready || preview.isExpired)
                    }
                }
            }.frame(height: 510)
        }.onDisappear { password = "" }
    }
}
