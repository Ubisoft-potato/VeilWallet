import SwiftUI
import AppKit
import WalletCore

struct PrivacyPoolView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var poolID = ""
    @ViewState private var noteID: UUID?
    @ViewState private var password = ""
    @ViewState private var importText = ""
    @ViewState private var revealed: String?
    @ViewState private var revealVisibility = UUID()
    @ViewState private var backedUp = false
    @ViewState private var directWithdrawalAccepted = false
    @ViewState private var progress = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var preview: TransactionPreview?
    @ViewState private var task: Task<Void, Never>?
    private var notes: [PrivacyNoteSummary] { model.privacyNotes.filter { $0.pool?.chainID == model.chainID } }
    private var selected: PrivacyNoteSummary? { notes.first { $0.id == noteID } }
    private var pool: PrivacyPool? { PrivacyPoolCatalog.find(poolID) }
    var body: some View {
        SheetFrame(title: L("message.non_custodial_privacy_pools"), subtitle: model.chain.name + L("message.tornado_cash_classic_fixed_denomination_native_asset_pools")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if PrivacyPoolCatalog.on(model.chainID).isEmpty {
                        Text(L("message.this_wallet_has_not_verified_and_adapted_a_native_non")).foregroundStyle(.orange)
                    } else {
                        Text(L("message.a_note_is_an_independent_claim_to_funds_a_recovery")).font(.system(size: 12)).foregroundStyle(.orange)
                        Picker(L("message.new_note_denomination_generation_only"), selection: $poolID) { ForEach(PrivacyPoolCatalog.on(model.chainID)) { pool in Text(pool.name).tag(pool.id) } }.disabled(busy)
                        if let pool { ReviewDetail(L("message.fixed_pool_contract"), pool.contract) }
                        FieldLabel(title: L("message.vault_password_verify_again_to_create_import_reveal_or_prove")) { SecureField(L("message.enter_local_vault_password"), text: $password).disabled(busy) }
                        HStack {
                            Button(L("message.generate_new_note")) { run { try await create() } }.disabled(busy || password.isEmpty || model.wallet?.canSign != true)
                            Text(L("message.randomly_generated_locally_and_encrypted_immediately")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        DisclosureGroup(L("message.import_a_standard_tornado_note")) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextEditor(text: $importText).font(.system(size: 11, design: .monospaced)).frame(height: 65).disabled(busy)
                                Button(L("message.import_encrypted")) { run { try await importNote() } }.disabled(busy || password.isEmpty || importText.isEmpty)
                            }
                        }
                        Divider()
                        Picker(L("message.local_notes_includes_other_wallets_and_imported_notes"), selection: $noteID) {
                            Text(L("message.select_note")).tag(Optional<UUID>.none)
                            ForEach(notes) { note in Text((note.pool?.name ?? note.poolID) + " · " + String(note.id.uuidString.prefix(8))).tag(Optional(note.id)) }
                        }.disabled(busy)
                        if let note = selected {
                            noteDetails(note)
                            HStack {
                                Button(L("message.verify_password_and_reveal_backup")) { run { try await reveal(note) } }.disabled(busy || password.isEmpty)
                                if let revealed { Button(L("message.copy_note_clear_after_30_seconds")) { model.copyAddress(revealed) }; Button(L("message.hide")) { self.revealed = nil } }
                            }
                            if let revealed {
                                Text(revealed).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12).background(Color.veilAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                Toggle(L("message.i_backed_up_the_complete_note_offline_and_understand_that"), isOn: $backedUp)
                            }
                            Button(L("message.check_the_offline_prover_and_preview_deposit")) { run { try await deposit(note) } }
                                .buttonStyle(PrimaryButton()).disabled(busy || !model.ready || !backedUp || note.depositHash != nil || note.withdrawalHash != nil || model.wallet?.canSign != true)
                            Divider()
                            Text(L("message.withdraw_to_the_current_signing_account")).font(.headline)
                            ReviewDetail(L("message.current_recipient_gas_paying_account"), model.address ?? L("message.select_an_account_first"))
                            Text(L("message.direct_withdrawals_require_the_recipient_to_pay_gas_use_an")).font(.system(size: 11)).foregroundStyle(.orange)
                            Toggle(L("message.i_understand_gas_funding_and_timing_correlation_risks"), isOn: $directWithdrawalAccepted).disabled(busy)
                            HStack {
                                Button(L("message.sync_the_pool_s_full_deposit_tree")) { run { try await synchronize(note) } }.disabled(busy || !model.ready)
                                Button(L("message.clear_this_pool_s_tree_cache")) { run { try await model.store.resetPrivacyTree(poolID: note.poolID); progress = L("message.the_pool_s_public_event_cache_was_cleared_notes_were") } }.disabled(busy)
                            }
                            Button(L("message.generate_proof_locally_and_preview_withdrawal")) { run { try await withdraw(note) } }.buttonStyle(PrimaryButton())
                                .disabled(busy || !model.ready || password.isEmpty || !directWithdrawalAccepted || note.withdrawalHash != nil || model.wallet?.canSign != true)
                        }
                        if !progress.isEmpty { Text(LS(progress)).font(.system(size: 11)).foregroundStyle(Color.veilGreen).fixedSize(horizontal: false, vertical: true) }
                        if busy { HStack { ProgressView().controlSize(.small); Button(L("message.cancel_current_task")) { task?.cancel(); Task { await model.proofRuntime.stop() } } } }
                        ErrorText(text: error)
                        Text(L("message.sync_queries_all_deposit_events_by_pool_contract_only_initial")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }.frame(height: 610)
        }.onAppear { poolID = PrivacyPoolCatalog.on(model.chainID).first?.id ?? "" }
            .onChange(of: noteID) { _, _ in revealed = nil; backedUp = false; directWithdrawalAccepted = false; progress = "" }
            .onChange(of: model.walletID) { _, _ in task?.cancel(); preview = nil; password = ""; revealed = nil }
            .onChange(of: model.chainID) { _, _ in task?.cancel(); preview = nil; password = ""; revealed = nil }
            .onDisappear { task?.cancel(); password = ""; importText = ""; revealed = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in revealVisibility = UUID(); revealed = nil }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview { EVMReviewView(preview: preview).environmentObject(model) }
            }
    }
    private func noteDetails(_ note: PrivacyNoteSummary) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                ReviewDetail(L("message.note_id_fixed_denomination"), note.id.uuidString + " · " + (note.pool?.name ?? note.poolID))
                if let hash = note.depositHash { ReviewDetail(L("message.local_deposit_hash_verify_broadcast_in_transactions"), hash) }
                if let hash = note.withdrawalHash { ReviewDetail(L("message.local_withdrawal_hash_verify_broadcast_in_transactions"), hash) }
                Text(L("message.the_submission_record_is_saved_before_broadcast_network_errors_never")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        task = Task { defer { busy = false; password = "" }; do { try await operation() } catch { if !Task.isCancelled { self.error = error.localizedDescription } } }
    }
    private func reloadNotes() async throws {
        let notes = try await model.vault.privacyNotes()
        guard model.unlocked, !Task.isCancelled else { throw WalletError.locked }; model.privacyNotes = notes
    }
    private func create() async throws {
        guard let walletID = model.walletID else { throw WalletError.locked }
        let note = try await model.vault.createPrivacyNote(poolID: poolID, walletID: walletID, password: password, runtime: model.proofRuntime)
        try await reloadNotes(); noteID = note.id; progress = L("message.the_note_is_encrypted_locally_verify_your_password_to_reveal")
    }
    private func importNote() async throws {
        let note = try await model.vault.importPrivacyNote(importText, password: password, runtime: model.proofRuntime)
        importText = ""; try await reloadNotes(); noteID = note.id; progress = L("message.the_note_was_imported_and_encrypted_no_on_chain_transaction")
    }
    private func reveal(_ note: PrivacyNoteSummary) async throws {
        let request = revealVisibility
        let value = try await model.vault.privacyNote(id: note.id, password: password)
        guard model.unlocked, !Task.isCancelled, NSApplication.shared.isActive, request == revealVisibility else { throw WalletError.invalid(L("message.return_to_the_wallet_window_and_verify_your_password_again")) }; revealed = value
    }
    private func deposit(_ note: PrivacyNoteSummary) async throws {
        guard backedUp, let pool = note.pool, let sender = model.address else { throw WalletError.invalid(L("message.back_up_the_complete_note_and_select_a_deposit_account")) }
        let walletID = model.walletID, client = PrivacyPoolClient(rpc: model.client())
        progress = L("message.checking_the_local_prover_and_on_chain_verifier_with_a")
        try await client.verifyPublicProver(pool: pool, runtime: model.proofRuntime)
        let result = try await client.prepareDeposit(note: note, sender: sender)
        guard model.ready, walletID == model.walletID, pool.chainID == model.chainID, !Task.isCancelled else { throw WalletError.locked }; preview = result; progress = L("message.checks_passed_the_deposit_is_not_signed_yet_review_the")
    }
    private func synchronize(_ note: PrivacyNoteSummary) async throws {
        guard let pool = note.pool else { throw WalletError.invalid(L("message.unknown_note_pool")) }
        let client = PrivacyPoolClient(rpc: model.client()), store = model.store
        let cached = try await store.loadPrivacyTree(poolID: pool.id)
        let result = try await client.synchronize(pool: pool, snapshot: cached) { value in
            try Task.checkCancellation(); try await store.savePrivacyTree(value.snapshot)
            await MainActor.run { progress = L("message.synced_through_block_0_1_with_2_deposits", value.snapshot.scannedBlock, value.targetBlock, value.snapshot.leaves.count) }
        }
        progress += result.complete ? L("message.this_sync_pass_is_complete") : L("message.this_batch_was_saved_click_again_to_continue_syncing")
    }
    private func withdraw(_ note: PrivacyNoteSummary) async throws {
        guard let pool = note.pool, let sender = model.address, directWithdrawalAccepted else { throw WalletError.invalid(L("message.acknowledge_the_direct_withdrawal_method_first")) }
        guard note.depositSender?.lowercased() != sender.lowercased() else { throw WalletError.invalid(L("message.select_an_independent_signing_recipient_do_not_withdraw_directly_to")) }
        let walletID = model.walletID, chainID = model.chainID
        let material = try PrivacyNoteMaterial(await model.vault.privacyNote(id: note.id, password: password))
        guard let tree = try await model.store.loadPrivacyTree(poolID: pool.id), !tree.leaves.isEmpty else { throw WalletError.invalid(L("message.sync_this_pool_s_complete_historical_deposit_tree_first")) }
        progress = L("message.generating_the_zero_knowledge_proof_in_an_offline_process_cancellation")
        let proof = try await model.proofRuntime.prove(note: material, leaves: tree.leaves, recipient: sender, relayer: "0x0000000000000000000000000000000000000000", fee: "0")
        guard model.ready, walletID == model.walletID, chainID == model.chainID, !Task.isCancelled else { throw WalletError.locked }
        let result = try await PrivacyPoolClient(rpc: model.client()).prepareWithdrawal(note: note, proof: proof, sender: sender)
        guard model.ready, walletID == model.walletID, chainID == model.chainID, !Task.isCancelled else { throw WalletError.locked }; preview = result; progress = L("message.local_proof_and_on_chain_verification_passed_review_the_recipient")
    }
}
struct PrivacyRetryView: View {
    let activity: Activity
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var error: String?
    @ViewState private var busy = false
    var body: some View {
        DisclosureGroup(L("message.re_enable_note_actions_after_a_failed_execution")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("message.recheck_the_on_chain_revert_and_confirmation_count_a_transaction")).font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField(L("message.vault_password"), text: $password)
                Button(L("message.verify_failed_receipt_and_release_this_submission_record")) {
                    busy = true; error = nil
                    Task {
                        defer { busy = false; password = "" }
                        do {
                            guard let id = activity.privacyNoteID, let value = activity.privacyKind, let kind = PrivacyTransactionIntent.Kind(rawValue: value) else { throw WalletError.invalid(L("message.note_record_missing")) }
                            try await model.vault.releaseFailedPrivacyTransaction(noteID: id, kind: kind, hash: activity.hash, password: password, rpc: model.client())
                            let notes = try await model.vault.privacyNotes()
                            guard model.unlocked else { return }; model.privacyNotes = notes
                            model.notice = L("message.the_original_transaction_was_confirmed_reverted_and_its_submission_record")
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || !model.ready || password.isEmpty || activity.chainID != model.chainID)
                ErrorText(text: error)
            }
        }.onDisappear { password = "" }
    }
}
