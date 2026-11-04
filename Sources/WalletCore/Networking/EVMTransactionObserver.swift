import Foundation
import BigInt

public extension RPCClient {
    var confirmationThreshold: UInt64 { chain.id == 56 ? 15 : 12 }
    func observe(activity: Activity) async throws -> TransactionObservation {
        guard activity.chainID == chain.id, (try? Data(strictHex: activity.hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_transaction_record_network_or_hash")) }
        try await verifyChain()
        let receipt = try await call("eth_getTransactionReceipt", params: [.string(activity.hash)])
        if receipt == .null {
            if activity.transaction?.observation.blockHash != nil, [.confirmed, .failed, .cancelled, .confirming, .replaced].contains(activity.phase) {
                return TransactionObservation(.reorged, detail: L("message.a_previously_mined_receipt_is_unavailable_possibly_due_to_reorganization"))
            }
            let tx = try await call("eth_getTransactionByHash", params: [.string(activity.hash)])
            if tx != .null {
                guard tx["hash"]?.string?.lowercased() == activity.hash.lowercased(), let sender = tx["from"]?.string, Ethereum.validateAddress(sender),
                      activity.transaction == nil || activity.transaction?.sender.lowercased() == sender.lowercased() else { throw WalletError.invalid(L("message.node_transaction_hash_or_sender_differs_from_the_local_record")) }
                if let text = activity.transaction?.sequence {
                    guard let nonce = tx["nonce"]?.string, try Ethereum.decodeQuantity(nonce) == BigUInt(text) else { throw WalletError.invalid(L("message.node_transaction_nonce_differs_from_the_local_record")) }
                }
                return TransactionObservation(.pending, detail: tx["blockHash"] == .null ? nil : L("message.the_node_reports_block_information_but_the_receipt_is_not"))
            }
            if activity.phase == .queued, activity.transaction?.broadcastAttempts == 0 { return TransactionObservation(.queued) }
            if let record = activity.transaction, let n = record.sequence, let nonce = BigUInt(n) {
                let latest = try await quantity("eth_getTransactionCount", [.string(record.sender), .string("latest")])
                if latest > nonce { return TransactionObservation(.nonceConsumed, detail: L("message.a_higher_nonce_alone_does_not_prove_success_refresh_every")) }
            }
            return TransactionObservation(.notSeen, detail: L("message.one_node_not_finding_a_transaction_does_not_prove_other"))
        }
        guard receipt["transactionHash"]?.string?.lowercased() == activity.hash.lowercased(), let status = receipt["status"]?.string,
              let height = receipt["blockNumber"]?.string, let hash = receipt["blockHash"]?.string,
              (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.the_receipt_lacks_a_valid_hash_block_or_execution_status")) }
        let outcome = try Ethereum.decodeQuantity(status), number = try Ethereum.decodeQuantity(height)
        guard outcome <= 1, number > 0 else { throw WalletError.invalid(L("message.invalid_receipt_execution_status_or_block_height")) }
        if let record = activity.transaction {
            guard receipt["from"]?.string?.lowercased() == record.sender.lowercased() else { throw WalletError.invalid(L("message.receipt_sender_differs_from_the_record")) }
        }
        let canonical = try await call("eth_getBlockByNumber", params: [.string(height), .bool(false)])
        guard canonical["number"] == .string(height), let canonicalHash = canonical["hash"]?.string, (try? Data(strictHex: canonicalHash).count) == 32 else { throw WalletError.invalid(L("message.the_node_has_no_valid_canonical_block")) }
        if canonicalHash.lowercased() != hash.lowercased() { return TransactionObservation(.reorged, detail: L("message.the_old_receipt_is_not_on_the_current_canonical_chain")) }
        let latest = try await call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        guard let head = latest["number"]?.string else { throw WalletError.invalid(L("message.latest_block_height_missing")) }
        let tip = try Ethereum.decodeQuantity(head)
        guard tip >= number, let confirmations = UInt64(exactly: tip - number + 1) else { throw WalletError.invalid(L("message.receipt_height_is_inconsistent_with_the_chain_head")) }
        let passed = confirmations >= confirmationThreshold
        var result = TransactionObservation(passed ? (outcome == 1 ? .confirmed : .failed) : .confirming)
        result.blockNumber = String(number); result.blockHash = hash.lowercased(); result.confirmations = confirmations; result.requiredConfirmations = confirmationThreshold; result.executionSucceeded = outcome == 1
        if let gas = receipt["gasUsed"]?.string, let price = receipt["effectiveGasPrice"]?.string {
            let used = try Ethereum.decodeQuantity(gas), rate = try Ethereum.decodeQuantity(price)
            guard used > 0, used.bitWidth <= 64, rate.bitWidth <= 256 else { throw WalletError.invalid(L("message.invalid_receipt_execution_fee")) }
            result.executionFee = String(used * rate)
        }
        if chain.evmFeeModel != .standard { result.detail = L("message.confirmations_use_this_execution_chain_s_local_threshold_they_do") }
        return result
    }
    /// A group is resolved only by a matching canonical receipt, never by the
    /// most recently broadcast hash or by a missing transaction response.
    func observeGroup(_ activities: [Activity]) async throws -> [UUID: TransactionObservation] {
        guard !activities.isEmpty, activities.count <= 64, let group = activities[0].transaction?.groupID,
              activities.allSatisfy({ $0.chainID == chain.id && $0.transaction?.groupID == group && $0.transaction?.sequence == activities[0].transaction?.sequence && $0.transaction?.sender.lowercased() == activities[0].transaction?.sender.lowercased() }) else { throw WalletError.invalid(L("message.invalid_or_oversized_transaction_group")) }
        var observations: [UUID: TransactionObservation] = [:]
        for activity in activities { try Task.checkCancellation(); observations[activity.id] = try await observe(activity: activity) }
        let winners = activities.filter { observations[$0.id]?.phase == .confirmed || observations[$0.id]?.phase == .failed }
        guard winners.count <= 1 else { throw WalletError.invalid(L("message.multiple_confirmed_receipts_share_one_nonce_the_node_view_conflicts")) }
        if let winner = winners.first, let outcome = observations[winner.id] {
            for activity in activities {
                if activity.id == winner.id {
                    if winner.transaction?.action == .cancel, outcome.executionSucceeded == true { observations[activity.id]?.phase = .cancelled }
                } else {
                    var other = TransactionObservation(.replaced); other.winningHash = winner.hash; other.blockHash = outcome.blockHash; other.blockNumber = outcome.blockNumber; other.confirmations = outcome.confirmations; other.requiredConfirmations = outcome.requiredConfirmations
                    other.detail = winner.transaction?.action == .cancel ? L("message.a_cancellation_in_this_group_confirmed_first_the_original_cannot") : L("message.another_transaction_in_this_group_reached_the_confirmation_threshold")
                    observations[activity.id] = other
                }
            }
        }
        return observations
    }
}
