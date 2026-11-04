import Foundation
import BigInt

public struct UTXOManagementPreview: Sendable {
    public let plan: NativeTransferPlan
    public let original: TransactionArchive
    public let groupID: UUID
    public let action: TransactionAction
    public let rate: BigUInt
    public let minimumFee: BigUInt
    public var isExpired: Bool { plan.isExpired }
}
public extension NativeTransferClient {
    func prepareUTXOManagement(archive: TransactionArchive, record: TransactionRecord, action: TransactionAction, rateText: String) async throws -> UTXOManagementPreview {
        try archive.validate()
        guard [.bitcoin, .litecoin].contains(chain.family), let old = archive.native, old.chainID == chain.id, [.speedUp, .cancel, .cpfp].contains(action),
              let profile = AccountProfile.find(old.profileID), let rate = BigUInt(rateText), rate > 0, rate <= 1_000_000 else { throw WalletError.invalid(L("message.invalid_utxo_management_type_or_fee_rate_use_integer_base")) }
        try await verifyUTXONetwork()
        let signed = try inspectUTXOArchive(archive)
        let source = try await rest("tx/" + archive.hash)
        guard source["txid"]?.string?.lowercased() == archive.hash.lowercased(), source["status"]?["confirmed"] == .bool(false) else { throw WalletError.invalid(L("message.the_parent_transaction_is_not_in_the_current_node_s")) }
        let originalFee = try integer(.string(old.payload.fee))
        guard try integer(source["fee"]) == originalFee, (try integer(source["weight"]) + 3) / 4 == signed else { throw WalletError.invalid(L("message.the_utxo_node_s_transaction_fee_size_does_not_match")) }
        let inputSize = try inputUpperSize(profile)
        var payload = old.payload
        payload.replaceable = true
        var fee: BigUInt, minimum: BigUInt, recipient = old.recipient, amount = old.amount
        if action == .cpfp {
            guard record.action != .cpfp else { throw WalletError.invalid(L("message.a_cpfp_child_already_exists_manage_that_child_this_version")) }
            // Package pricing here covers one parent and one child. Require all
            // parent inputs confirmed, rather than undercounting ancestors.
            for input in old.payload.inputs {
                let status = try await rest("tx/" + input.txid + "/status")
                guard status["confirmed"] == .bool(true) else { throw WalletError.invalid(L("message.the_parent_still_has_unconfirmed_ancestors_this_single_level_cpfp")) }
            }
            let change = try integer(.string(old.payload.change))
            let own = chain.family == .litecoin ? try Litecoin.addressInfo(old.sender).canonicalAddress : old.sender
            let oldTo = chain.family == .litecoin ? try Litecoin.addressInfo(old.recipient).canonicalAddress : old.recipient
            let index: UInt32, available: BigUInt
            if change > 0 { index = 1; available = change }
            else if own == oldTo { index = 0; available = old.amount }
            else { throw WalletError.invalid(L("message.this_transaction_has_no_change_output_spendable_by_this_wallet")) }
            let spent = try await rest("tx/" + archive.hash + "/outspend/" + String(index))
            guard spent["spent"] == .bool(false) else { throw WalletError.invalid(L("message.the_change_was_already_spent_manage_the_existing_child_transaction")) }
            let childSize = BigUInt(12 + inputSize + 43)
            let packageTarget = rate * (signed + childSize)
            minimum = max(childSize, packageTarget > originalFee ? packageTarget - originalFee : 1)
            fee = minimum
            guard available >= fee + 1000 else { throw WalletError.invalid(L("message.insufficient_change_for_the_cpfp_fee_and_a_non_dust")) }
            payload = NativeTransferPayload(); payload.from = old.sender; payload.to = own; payload.amount = String(available - fee); payload.change = "0"; payload.fee = String(fee); payload.replaceable = true
            payload.inputs = [.init(txid: archive.hash, index: index, value: String(available), previous: archive.signedPayload)]
            recipient = own; amount = available - fee
        } else {
            guard record.action != .cpfp else { throw WalletError.invalid(L("message.the_cpfp_child_spends_an_unconfirmed_parent_raise_the_parent")) }
            guard old.payload.replaceable == true else { throw WalletError.invalid(L("message.the_original_transaction_did_not_enable_rbf_cpfp_may_be")) }
            let size = BigUInt(12 + old.payload.inputs.count * inputSize + (action == .cancel ? 43 : 86))
            let evictedFees = try await replacementPackageFees(rootHash: archive.hash)
            minimum = max((originalFee * 125 + 99) / 100, evictedFees + size)
            fee = max(minimum, rate * size)
            let total = try old.payload.inputs.reduce(BigUInt(0)) { try $0 + integer(.string($1.value)) }
            if action == .cancel {
                guard total >= fee + 1000 else { throw WalletError.invalid(L("message.insufficient_balance_for_the_cancellation_fee_and_a_non_dust")) }
                recipient = chain.family == .litecoin ? try Litecoin.addressInfo(old.sender).canonicalAddress : old.sender; amount = total - fee; payload.to = recipient; payload.amount = String(amount); payload.change = "0"
            } else {
                guard total >= old.amount + fee else { throw WalletError.invalid(L("message.original_input_change_is_insufficient_for_a_fee_increase_speed")) }
                var change = total - old.amount - fee
                if change < 1000 { fee += change; change = 0 }; payload.change = String(change)
            }
            payload.fee = String(fee)
        }
        let built = try build(payload, profile: profile)
        guard let unsigned = built.unsigned else { throw WalletError.invalid(L("message.unable_to_build_the_utxo_management_preview")) }
        let plan = NativeTransferPlan(chainID: chain.id, profileID: profile.id, family: chain.family, sender: old.sender, recipient: recipient, amount: amount, feeBudget: fee, preparedAt: Date(), details: [L("message.action_c19eeeca") + action.label, L("message.fee_ae20b6ea") + String(fee) + L("message.base_units_using_a_conservative_vbyte_upper_bound"), L("message.target_fee_rate") + String(rate) + L("message.base_units_vbyte"), action == .cpfp ? L("message.spends_local_change_to_raise_the_parent_child_package_fee") : L("message.reuses_all_original_inputs_replacement_and_cancellation_depend_on_miner"), L("message.node_replacement_and_descendant_policies_may_reject_the_transaction_no")], payload: payload, unsigned: unsigned)
        return .init(plan: plan, original: archive, groupID: action == .cpfp ? UUID() : record.groupID, action: action, rate: rate, minimumFee: minimum)
    }
    func revalidateUTXOManagement(_ preview: UTXOManagementPreview) async throws {
        guard !preview.isExpired, preview.plan.chainID == chain.id, let old = preview.original.native, preview.plan.sender == old.sender else { throw WalletError.invalid(L("message.the_utxo_management_preview_expired_or_the_account_changed")) }
        let archive = preview.original
        let record = archive.activity?.transaction ?? TransactionRecord(groupID: preview.groupID, sender: old.sender, profileID: old.profileID, sequence: nil, nativeCost: old.amount + old.feeBudget)
        let fresh = try await prepareUTXOManagement(archive: archive, record: record, action: preview.action, rateText: String(preview.rate))
        guard preview.plan.feeBudget >= fresh.minimumFee, preview.plan.payload.inputs == fresh.plan.payload.inputs,
              preview.plan.payload.to == fresh.plan.payload.to, preview.plan.payload.amount == fresh.plan.payload.amount,
              preview.plan.payload.change == fresh.plan.payload.change, preview.plan.payload.fee == fresh.plan.payload.fee else { throw WalletError.invalid(L("message.inputs_descendant_fees_or_change_changed_preview_again")) }
        // A replacement must never conflict with an unrelated confirmed spend.
        for input in preview.plan.payload.inputs {
            let spend = try await rest("tx/" + input.txid + "/outspend/" + String(input.index))
            guard spend["spent"] == .bool(false) || (spend["spent"] == .bool(true) && spend["txid"]?.string?.lowercased() == archive.hash.lowercased() && preview.action != .cpfp) else { throw WalletError.invalid(L("message.other_transactions_are_using_these_utxo_inputs")) }
        }
    }
    func inspectUTXOArchive(_ archive: TransactionArchive) throws -> BigUInt {
        guard let native = archive.native, let profile = AccountProfile.find(native.profileID), [.bitcoin, .litecoin].contains(native.family) else { throw WalletError.invalid(L("message.no_verifiable_utxo_signature")) }
        let result = try MultichainCrypto.execute(.init(action: "transferInspect", profile: profile, transfer: native.payload, signedTransaction: archive.signedPayload))
        guard result.valid == true, result.hash?.lowercased() == archive.hash.lowercased(), result.unsigned == native.unsigned, let text = result.virtualSize, let size = BigUInt(text), size > 0 else { throw WalletError.invalid(L("message.utxo_signature_hash_size_mismatch")) }; return size
    }
}
extension NativeTransferClient {
    private func inputUpperSize(_ profile: AccountProfile) throws -> Int {
        switch profile.variant { case "legacy": return 181; case "nested", "nested-compat": return 92; case "segwit": return 69; case "taproot": return 58; default: throw WalletError.invalid(L("message.this_script_does_not_support_single_key_utxo_management")) }
    }
    private func replacementPackageFees(rootHash: String) async throws -> BigUInt {
        var seen = Set<String>(), queue = [rootHash], total: BigUInt = 0
        while !queue.isEmpty {
            try Task.checkCancellation(); let hash = queue.removeFirst()
            if !seen.insert(hash.lowercased()).inserted { continue }
            guard seen.count <= 25 else { throw WalletError.invalid(L("message.unconfirmed_descendants_exceed_the_25_transaction_analysis_limit_replacement_fees")) }
            let tx = try await rest("tx/" + hash)
            guard tx["txid"]?.string?.lowercased() == hash.lowercased(), tx["status"]?["confirmed"] == .bool(false), case .array(let outputs) = tx["vout"], outputs.count <= 64 else { throw WalletError.invalid(L("message.unconfirmed_descendant_metadata_is_incomplete_or_too_large")) }
            total += try integer(tx["fee"])
            let spends = try await rest("tx/" + hash + "/outspends")
            guard case .array(let rows) = spends, rows.count == outputs.count else { throw WalletError.invalid(L("message.the_node_did_not_provide_a_complete_descendant_spending_list")) }
            for row in rows {
                guard row["spent"] == .bool(false) || row["spent"] == .bool(true) else { throw WalletError.invalid(L("message.invalid_descendant_spending_status")) }
                if row["spent"] == .bool(true) {
                    guard row["status"]?["confirmed"] == .bool(false), let child = row["txid"]?.string, (try? Data(strictHex: child).count) == 32 else { throw WalletError.invalid(L("message.a_descendant_is_confirmed_or_its_status_is_inconsistent_query")) }; queue.append(child)
                }
            }
        }
        return total
    }
}
