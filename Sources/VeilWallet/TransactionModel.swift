import Foundation
import WalletCore
import BigInt

struct TransferDraft {
    let recipient: String
    let amount: String
    var assetID = "native"
    var memo = ""
}

@MainActor extension AppModel {
    var reservedUTXOInputs: Set<String> { Set(local.activities.filter { $0.chainID == chainID && $0.phase != .discarded }.flatMap { $0.transaction?.spentOutputs ?? [] }) }
    func nativeClient() -> NativeTransferClient { .init(transport: TorTransport(gate: gate), chain: chain, isolation: isolationKey, reservedInputs: reservedUTXOInputs) }
    func ensureNativeAccountAvailable() throws {
        guard ![.bitcoin, .litecoin].contains(chain.family) else { return }
        if activities.contains(where: { $0.isUnresolved && ($0.transaction?.sender == address || $0.transaction == nil) }) { throw WalletError.invalid(L("message.this_account_has_an_unverified_transaction_confirm_its_status_expiry")) }
    }
    func ensureLegacyHistoryManaged() throws {
        guard chain.isEVM else { return }
        if activities.contains(where: { $0.transaction == nil && $0.isUnresolved }) { throw WalletError.invalid(L("message.an_older_transaction_remains_unverified_refresh_its_receipt_or_adopt")) }
    }
    func ensureFreshReplacement(_ preview: TransactionPreview) throws {
        guard let ref = preview.replacement, ref.action != .nonceRepair else { return }
        guard local.activities.filter({ $0.transaction?.groupID == ref.groupID && $0.phase != .discarded }).count < 64 else { throw WalletError.invalid(L("message.this_replacement_group_reached_64_attempts_verify_existing_transactions_first")) }
        guard let latest = local.activities.filter({ $0.transaction?.groupID == ref.groupID && $0.phase != .discarded }).max(by: { $0.date < $1.date }), latest.id == ref.activityID, latest.hash.lowercased() == ref.hash.lowercased(), latest.isUnresolved else { throw WalletError.invalid(L("message.this_transaction_group_changed_create_a_fresh_replacement_preview")) }
    }
    func privacySource(for preview: TransactionPreview) async throws -> PrivacyTransactionIntent? {
        if case .privacy(let intent, _) = preview.purpose { return intent }
        guard let ref = preview.replacement else { return nil }
        for activity in local.activities.filter({ $0.transaction?.groupID == ref.groupID && $0.privacyNoteID != nil }) {
            let archive = try await store.transaction(id: activity.id)
            if let evm = archive.evm, case .privacy(let intent, _) = evm.purpose { return intent }
        }
        return nil
    }
    func updateTransaction(_ id: UUID, phase: TransactionPhase) {
        guard let index = local.activities.firstIndex(where: { $0.id == id }) else { return }
        local.activities[index].transaction?.observation = TransactionObservation(phase)
        local.activities[index].status = phase.label
    }
    func markBroadcast(_ id: UUID, operation: UUID) async throws {
        guard operation == epoch, networkSessionReady, let index = local.activities.firstIndex(where: { $0.id == id }), var record = local.activities[index].transaction, record.maySubmitAgain else { throw WalletError.invalid(L("message.the_session_changed_or_fewer_than_30_seconds_passed_since")) }
        var archive = try await store.transaction(id: id)
        guard operation == epoch, networkSessionReady, archive.chainID == chainID, archive.sender == address else { throw WalletError.networkBlocked }
        record.observation = TransactionObservation(.broadcastUnknown); record.broadcastAttempts += 1; record.lastBroadcastAt = Date()
        local.activities[index].transaction = record; local.activities[index].status = record.observation.phase.label
        archive.activity = local.activities[index]
        // Archive first. On a crash, startup uses the higher attempt counter and
        // cannot mistake a possibly-sent transaction for an unbroadcast draft.
        try await store.saveTransaction(archive)
        guard operation == epoch, networkSessionReady else { throw WalletError.networkBlocked }
        try await saveLocal()
        guard operation == epoch, networkSessionReady else { throw WalletError.networkBlocked }
    }
    func refreshEVMGroup(_ activity: Activity, operation: UUID) async throws {
        let rpc = client()
        if let group = activity.transaction?.groupID {
            let members = local.activities.filter { $0.transaction?.groupID == group && $0.chainID == chainID && $0.phase != .discarded }
            guard !members.isEmpty else { return }
            let result = try await rpc.observeGroup(members)
            guard operation == epoch, unlocked else { return }
            for (id, observation) in result {
                if let index = local.activities.firstIndex(where: { $0.id == id }) { local.activities[index].transaction?.observation = observation; local.activities[index].status = observation.phase.label }
            }
        } else {
            let result = try await rpc.observe(activity: activity)
            guard operation == epoch, unlocked else { return }
            if let index = local.activities.firstIndex(where: { $0.id == activity.id }) { local.activities[index].status = result.phase.label }
        }
        try await saveLocal()
    }
    func refreshNativeActivity(_ activity: Activity, operation: UUID) async throws {
        if activity.phase == .discarded || (activity.phase == .queued && activity.transaction?.broadcastAttempts == 0) { return }
        if chain.family == .monero {
            if let wallet, monero.walletID != wallet.id {
                try await vault.openMonero(runtime: monero, walletID: wallet.id, node: chain.rpcURL, restoreHeight: moneroRestoreHeight)
                _ = try await monero.synchronize()
            }
            let outcome = try await monero.observe(hash: activity.hash)
            guard operation == epoch, unlocked, let index = local.activities.firstIndex(where: { $0.id == activity.id }) else { return }
            local.activities[index].transaction?.observation = outcome; local.activities[index].status = outcome.phase.label
        } else {
            let archive = activity.transaction == nil ? nil : try await store.transaction(id: activity.id)
            let observation = try await nativeClient().observe(activity: activity, archive: archive)
            guard operation == epoch, unlocked, let index = local.activities.firstIndex(where: { $0.id == activity.id }) else { return }
            local.activities[index].transaction?.observation = observation; local.activities[index].status = observation.phase.label
        }
        try await saveLocal()
    }
    func transactionStatus(hash: String) -> String { local.activities.last(where: { $0.hash == hash })?.statusLabel ?? L("message.the_local_hash_is_saved_verify_its_status_in_transactions") }
    func savedTransactionHash(matching preview: TransactionPreview, walletID: UUID, since: Date, operation: UUID) async throws -> String? {
        guard operation == epoch, unlocked, self.walletID == walletID, chainID == preview.transaction.chainID, address == preview.sender else { return nil }
        // A send can throw after journaling a signature (including a lost RPC
        // response). Match the exact reviewed transaction, never just its nonce.
        for item in local.activities.reversed().filter({ $0.walletID == walletID && $0.chainID == preview.transaction.chainID && $0.date >= since && $0.transaction?.sender == preview.sender }) {
            let archive = try await store.transaction(id: item.id)
            guard operation == epoch, unlocked, self.walletID == walletID, chainID == preview.transaction.chainID, address == preview.sender else { return nil }
            if archive.evm?.transaction == preview.transaction { return archive.hash }
        }
        return nil
    }
    func checkDexApproval(hash: String) async throws -> DexApprovalProgress {
        guard ready, let walletID, let sender = address,
              let item = local.activities.first(where: { $0.hash.lowercased() == hash.lowercased() && $0.walletID == walletID && $0.chainID == chainID && $0.transaction?.sender.lowercased() == sender.lowercased() }) else { throw WalletError.invalid(L("message.this_account_has_no_such_approval_record_verify_it_in")) }
        let operation = epoch, network = chainID
        busy = true; defer { if operation == epoch { busy = false } }
        try await refreshEVMGroup(item, operation: operation)
        guard !Task.isCancelled, operation == epoch, networkSessionReady, self.walletID == walletID, chainID == network, address == sender else { throw WalletError.networkBlocked }
        return DexApprovalProgress.resolve(hash: hash, activities: local.activities, walletID: walletID, chainID: network, sender: sender)
    }
    func savedNativeTransactionHash(matching plan: NativeTransferPlan, walletID: UUID, since: Date, operation: UUID) async throws -> String? {
        guard operation == epoch, unlocked, self.walletID == walletID, chainID == plan.chainID, address == plan.sender else { return nil }
        for item in local.activities.reversed().filter({ $0.walletID == walletID && $0.chainID == plan.chainID && $0.date >= since && $0.transaction?.sender == plan.sender }) {
            let archive = try await store.transaction(id: item.id)
            guard operation == epoch, unlocked, self.walletID == walletID, chainID == plan.chainID, address == plan.sender else { return nil }
            if archive.native?.sameTransaction(as: plan) == true { return archive.hash }
        }
        return nil
    }
    func checkTronDexApproval(hash: String) async throws -> DexApprovalProgress {
        guard ready, chain.family == .tron, let walletID, let sender = address,
              let item = local.activities.first(where: { $0.hash.lowercased() == hash.lowercased() && $0.walletID == walletID && $0.chainID == TronAddress.chainID && $0.transaction?.sender == sender }) else {
            throw WalletError.invalid(L("message.this_account_has_no_such_tron_approval_record"))
        }
        let session = epoch
        busy = true; defer { if session == epoch { busy = false } }
        let archive = try await store.transaction(id: item.id)
        guard let plan = archive.native,
              let call = plan.contract, ["approve(address,uint256)", "approve(address,address,uint160,uint48)"].contains(call.signature) else { throw WalletError.invalid(L("message.the_record_is_not_a_tron_approval")) }
        try await refreshNativeActivity(item, operation: session)
        // This operation owns busy; validate the live session without blocking
        // on the UI flag that remains set until the deferred cleanup above.
        guard !Task.isCancelled, session == epoch, networkSessionReady, self.walletID == walletID, chainID == TronAddress.chainID, address == sender else { throw WalletError.networkBlocked }
        return .resolveTron(hash: hash, activities: local.activities, walletID: walletID, sender: sender, chainID: chainID)
    }
    func pendingTronDexApproval(for quote: TronDexQuote) async throws -> (hash: String, title: String)? {
        guard ready, chainID == quote.chainID, let walletID, address == quote.sender else { throw WalletError.locked }
        let session = epoch
        for item in local.activities.reversed().filter({ $0.walletID == walletID && $0.chainID == quote.chainID && $0.isUnresolved && $0.transaction?.profileID == "tron" && $0.transaction?.sender == quote.sender }) {
            let archive = try await store.transaction(id: item.id)
            guard !Task.isCancelled, session == epoch, ready, self.walletID == walletID, chainID == quote.chainID, address == quote.sender else { throw WalletError.networkBlocked }
            if let plan = archive.native, let call = plan.contract, quote.matchesApproval(call) {
                return (item.hash, call.signature == "approve(address,address,uint160,uint48)" ? DexApprovalRequirement.permit2.title : (call.arguments.last == "0" ? DexApprovalRequirement.reset.title : DexApprovalRequirement.token.title))
            }
        }
        return nil
    }
    func pendingDexApproval(for quote: DexQuote) async throws -> (hash: String, title: String)? {
        guard ready, chainID == quote.chainID, let walletID, let sender = address else { throw WalletError.locked }
        let operation = epoch
        for item in local.activities.reversed().filter({ $0.walletID == walletID && $0.chainID == quote.chainID && $0.isUnresolved && $0.transaction?.sender.lowercased() == sender.lowercased() && [.original, .speedUp].contains($0.transaction?.action) }) {
            let archive = try await store.transaction(id: item.id)
            guard !Task.isCancelled, operation == epoch, ready, self.walletID == walletID, chainID == quote.chainID, address == sender else { throw WalletError.networkBlocked }
            if let call = archive.evm?.purpose.invocation, quote.matchesApproval(call) {
                let title = call.signature == "approve(address,address,uint160,uint48)" ? DexApprovalRequirement.permit2.title : (call.arguments.last == "0" ? DexApprovalRequirement.reset.title : DexApprovalRequirement.token.title)
                return (item.hash, title)
            }
        }
        return nil
    }
    func prepareUTXOManagement(_ activity: Activity, action: TransactionAction, rate: String) async throws -> UTXOManagementPreview {
        guard ready, let record = activity.transaction, record.sender == address else { throw WalletError.invalid(L("message.the_current_account_does_not_match_this_transaction")) }
        let operation = epoch, archive = try await store.transaction(id: activity.id)
        let result = try await nativeClient().prepareUTXOManagement(archive: archive, record: record, action: action, rateText: rate)
        guard operation == epoch, ready else { throw WalletError.locked }; return result
    }
    func sendUTXOManagement(_ preview: UTXOManagementPreview, password: String) async throws -> String {
        guard ready, let wallet, let account, wallet.canSign, account.networkAddress == preview.plan.sender else { throw WalletError.locked }
        let operation = epoch, client = nativeClient(); busy = true; defer { if operation == epoch { busy = false } }
        guard let latest = local.activities.filter({ $0.transaction?.groupID == preview.original.activity?.transaction?.groupID && $0.phase != .discarded }).max(by: { $0.date < $1.date }), latest.id == preview.original.activityID, latest.isUnresolved else { throw WalletError.invalid(L("message.the_utxo_group_changed_recheck_the_latest_attempt")) }
        if preview.action == .cpfp, !Set(preview.plan.spentOutputs).isDisjoint(with: reservedUTXOInputs) { throw WalletError.invalid(L("message.a_local_child_transaction_already_reserved_the_parent_s_change")) }
        try await client.revalidateUTXOManagement(preview)
        let signed = try await vault.signNative(plan: preview.plan, walletID: wallet.id, password: password)
        guard operation == epoch, networkSessionReady, !preview.isExpired else { throw WalletError.networkBlocked }
        var activity = Activity(walletID: wallet.id, chainID: chainID, hash: signed.hash, to: preview.plan.recipient, amount: Ethereum.formatUnits(preview.plan.amount, decimals: chain.decimals, precision: chain.decimals), symbol: chain.symbol)
        activity.transaction = .native(preview.plan, groupID: preview.groupID, action: preview.action, parentID: preview.original.activityID)
        activity.operation = preview.action.label + " · " + chain.symbol; activity.status = activity.statusLabel
        var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, plan: preview.plan, signed: signed); archive.activity = activity
        try await store.saveTransaction(archive)
        guard operation == epoch, networkSessionReady else { throw WalletError.networkBlocked }
        local.activities.append(activity); try await saveLocal(); try await markBroadcast(activity.id, operation: operation)
        do { let hash = try await client.broadcast(signed); guard operation == epoch else { return hash }; updateTransaction(activity.id, phase: .submitted); try await saveLocal(); return hash }
        catch { if operation == epoch { notice = L("message.utxo_replacement_child_broadcast_is_unverified_the_original_payment_may") }; throw error }
    }
    func discardQueued(_ activity: Activity, password: String) async throws {
        guard ready, let wallet, let account, let record = activity.transaction, record.observation.phase == .queued, record.broadcastAttempts == 0, record.sender == account.networkAddress else { throw WalletError.invalid(L("message.only_local_queued_transactions_that_were_never_broadcast_can_be")) }
        let operation = epoch; busy = true; defer { if operation == epoch { busy = false } }
        let archive = try await store.transaction(id: activity.id)
        guard archive.activity?.transaction?.broadcastAttempts == 0 else { throw WalletError.invalid(L("message.the_archive_records_a_broadcast_attempt_it_cannot_be_discarded")) }
        if archive.evm?.replacement == nil, let text = record.sequence, let nonce = BigUInt(text) {
            guard !local.activities.contains(where: { $0.chainID == chainID && $0.phase != .discarded && $0.transaction?.sender == record.sender && ($0.transaction?.sequence.flatMap { BigUInt($0) }.map { $0 > nonce } ?? false) }) else { throw WalletError.invalid(L("message.higher_nonces_are_queued_behind_this_item_work_backward_from")) }
        }
        try await vault.authorizeAccount(walletID: wallet.id, profileID: account.profileID, sender: account.networkAddress, password: password)
        if let p = archive.evm, let intent = try await privacySource(for: p) {
            try await vault.authorizeArchivedPrivacy(intent, archive: archive, password: password)
            try await vault.releaseUnbroadcastPrivacy(intent, archive: archive, password: password)
            privacyNotes = try await vault.privacyNotes()
        }
        try await store.removeUnbroadcastArchive(id: activity.id)
        guard operation == epoch, unlocked else { throw WalletError.locked }; updateTransaction(activity.id, phase: .discarded); try await saveLocal()
    }
    func rebuild(_ activity: Activity, acknowledged: Bool) async throws {
        guard ready, acknowledged, [.failed, .cancelled, .expired, .discarded].contains(activity.phase) else { throw WalletError.invalid(L("message.only_failed_cancelled_expired_or_never_broadcast_records_can_be")) }
        let source = local.activities.filter { $0.transaction?.groupID == activity.transaction?.groupID && $0.transaction?.action == .original }.min(by: { $0.date < $1.date }) ?? activity
        let archive = try await store.transaction(id: source.id)
        if let p = archive.evm {
            switch p.purpose {
            case .transfer: transferDraft = TransferDraft(recipient: p.recipient, amount: p.amount, assetID: p.token?.id ?? "native"); sheet = .send
            case .swap: sheet = .swap
            case .bridge: sheet = .bridge
            case .privacy: sheet = .privacyPool
            case .contract: sheet = .contract
            }
        } else if let p = archive.native, p.contract == nil {
            transferDraft = TransferDraft(recipient: p.recipient, amount: Ethereum.formatUnits(p.amount, decimals: chain.decimals, precision: chain.decimals), memo: p.payloadMemo); sheet = .send
        } else if let p = archive.monero {
            transferDraft = TransferDraft(recipient: p.recipient, amount: Ethereum.formatUnits(p.amount, decimals: 12, precision: 12)); sheet = .send
        } else { throw WalletError.invalid(L("message.return_to_the_original_protocol_to_requote_a_contract_transaction")) }
    }
}

@MainActor extension AppModel {
    func refreshUTXOGroup(_ activity: Activity, operation: UUID) async throws {
        guard let group = activity.transaction?.groupID else { try await refreshNativeActivity(activity, operation: operation); return }
        let members = local.activities.filter { $0.transaction?.groupID == group && $0.phase != .discarded }
        var result: [UUID: TransactionObservation] = [:]
        for member in members {
            let archive = try await store.transaction(id: member.id)
            result[member.id] = try await nativeClient().observe(activity: member, archive: archive)
        }
        guard operation == epoch, unlocked else { throw WalletError.locked }
        let winners = members.filter { result[$0.id]?.phase == .confirmed }
        guard winners.count <= 1 else { throw WalletError.invalid(L("message.conflicting_confirmed_receipts_were_found_for_one_input_group_local")) }
        if let winner = winners.first {
            for member in members where member.id != winner.id { var observation = TransactionObservation(.replaced); observation.winningHash = winner.hash; result[member.id] = observation }
            if winner.transaction?.action == .cancel { result[winner.id]?.phase = .cancelled }
        }
        for (id, observation) in result { if let index = local.activities.firstIndex(where: { $0.id == id }) { local.activities[index].transaction?.observation = observation; local.activities[index].status = observation.phase.label } }
        try await saveLocal()
    }
    func refreshTransactionQueue() async {
        guard ready else { return }
        let operation = epoch; busy = true; defer { if operation == epoch { busy = false } }
        do {
            var groups = Set<UUID>()
            // Explicit user action, bounded current wallet / network scope.
            for activity in activities.prefix(50) {
                guard operation == epoch, networkSessionReady else { throw WalletError.networkBlocked }
                let group = activity.transaction?.groupID ?? activity.id
                guard groups.insert(group).inserted else { continue }
                if chain.isEVM { try await refreshEVMGroup(activity, operation: operation) }
                else if [.bitcoin, .litecoin].contains(chain.family) { try await refreshUTXOGroup(activity, operation: operation) }
                else { try await refreshNativeActivity(activity, operation: operation) }
            }
        } catch { if operation == epoch { self.error = error.localizedDescription } }
    }
    func prepareReplacement(_ activity: Activity, action: TransactionAction, maxFee: String? = nil, tip: String? = nil) async throws -> TransactionPreview {
        guard ready, chain.isEVM, let record = activity.transaction, record.sender.lowercased() == address?.lowercased(), record.broadcastAttempts > 0 else { throw WalletError.invalid(L("message.select_a_transaction_from_the_current_signing_account_that_was")) }
        let operation = epoch
        let archive = try await store.transaction(id: activity.id)
        let preview = try await client().prepareReplacement(archive: archive, record: record, action: action, maxFeeGwei: maxFee, priorityFeeGwei: tip)
        guard operation == epoch, ready else { throw WalletError.locked }; return preview
    }
    func adoptTransaction(_ activity: Activity) async throws {
        guard ready, let address, chain.isEVM, activity.transaction == nil else { throw WalletError.invalid(L("message.this_record_does_not_need_adoption_or_the_current_account")) }
        let operation = epoch; busy = true; defer { if operation == epoch { busy = false } }
        let (saved, record) = try await client().adopt(activity: activity, sender: address)
        guard operation == epoch, unlocked, let index = local.activities.firstIndex(where: { $0.id == activity.id }) else { throw WalletError.locked }
        var archive = saved, adopted = local.activities[index]; adopted.transaction = record; adopted.status = record.observation.phase.label; archive.activity = adopted
        try await store.saveTransaction(archive)
        guard operation == epoch, unlocked else { throw WalletError.locked }; local.activities[index] = adopted; try await saveLocal()
    }
    func resubmit(_ activity: Activity, password: String) async throws -> String {
        guard ready, let wallet, let account, wallet.canSign, let record = activity.transaction, record.sender == account.networkAddress, record.maySubmitAgain else { throw WalletError.invalid(L("message.select_a_pending_transaction_from_the_current_account_and_verify")) }
        let operation = epoch, rpc = client(), native = nativeClient()
        busy = true; defer { if operation == epoch { busy = false } }
        let archive = try await store.transaction(id: activity.id)
        guard let latest = local.activities.filter({ $0.transaction?.groupID == record.groupID && $0.phase != .discarded }).max(by: { $0.date < $1.date }), latest.id == activity.id else { throw WalletError.invalid(L("message.a_newer_signed_replacement_exists_refresh_the_group_and_resolve")) }
        try await vault.authorizeAccount(walletID: wallet.id, profileID: account.profileID, sender: account.networkAddress, password: password)
        if let evm = archive.evm {
            let preview = try rpc.replayPreview(archive: archive, record: record)
            try await rpc.revalidate(preview)
            if let intent = try await privacySource(for: preview) {
                try await vault.authorizeArchivedPrivacy(intent, archive: archive, password: password)
                privacyNotes = try await vault.privacyNotes()
            }
            let state = try await rpc.nonceState(sender: archive.sender)
            guard state.pending >= evm.transaction.nonce else { throw WalletError.invalid(L("message.an_earlier_nonce_has_not_reached_the_node_this_transaction")) }
        } else if archive.monero != nil {
            try await vault.openMonero(runtime: monero, walletID: wallet.id, node: chain.rpcURL, restoreHeight: moneroRestoreHeight)
            _ = try await monero.synchronize()
            let observation = try await monero.observe(hash: archive.hash)
            guard !observation.phase.isFinal, observation.phase != .confirming else { throw WalletError.invalid(L("message.the_original_xmr_transaction_is_mined_or_failed_verify_it")) }
        } else { try await native.validateReplay(archive: archive) }
        guard operation == epoch, networkSessionReady, walletID == wallet.id, chainID == archive.chainID, address == archive.sender else { throw WalletError.networkBlocked }
        try await markBroadcast(activity.id, operation: operation)
        do {
            let hash: String
            if archive.evm != nil { hash = try await rpc.broadcast(Data(strictHex: archive.signedPayload)) }
            else if archive.monero != nil { hash = try await monero.relayArchive(archive) }
            else { hash = try await native.broadcastArchive(archive) }
            guard operation == epoch, unlocked else { return hash }
            updateTransaction(activity.id, phase: .submitted); try await saveLocal(); return hash
        } catch {
            if operation == epoch { notice = L("message.rebroadcast_status_is_unverified_the_hash_is_unchanged_and_no") }; throw error
        }
    }
    func syncPrivacyOutcome(_ activity: Activity, password: String) async throws {
        guard ready, let group = activity.transaction?.groupID else { throw WalletError.invalid(L("message.note_transaction_group_missing")) }
        let operation = epoch
        guard let winner = local.activities.first(where: { $0.transaction?.groupID == group && [.confirmed, .failed, .cancelled].contains($0.phase) }) else { throw WalletError.invalid(L("message.refresh_the_group_and_wait_for_success_revert_or_cancellation")) }
        let winningArchive = try await store.transaction(id: winner.id)
        var intent: PrivacyTransactionIntent?
        for member in local.activities.filter({ $0.transaction?.groupID == group && $0.privacyNoteID != nil }) {
            if let p = try await store.transaction(id: member.id).evm, case .privacy(let saved, _) = p.purpose { intent = saved; break }
        }
        guard let intent else { throw WalletError.invalid(L("message.original_note_intent_not_found")) }
        try await vault.reconcilePrivacy(intent, winning: winner, archive: winningArchive, password: password, rpc: client())
        guard operation == epoch, unlocked else { throw WalletError.locked }; privacyNotes = try await vault.privacyNotes()
        notice = L("message.the_note_s_submission_record_was_reconciled_with_the_confirmed")
    }
}
