import Foundation
import BigInt

extension EVMTransactionPurpose {
    /// Renew only the local inspection time. Preserve the original calldata,
    /// on-chain deadline, minimum output, recipient, amount and message fee.
    func forFeeRevalidation() -> EVMTransactionPurpose {
        switch self {
        case .swap(let q):
            return .swap(DexQuote(chainID: q.chainID, input: q.input, output: q.output, amountIn: q.amountIn, amountOut: q.amountOut, minimumOut: q.minimumOut, slippageBPS: q.slippageBPS, path: q.path, deadline: q.deadline, quotedAt: Date(), invocation: q.invocation, venueID: q.venueID, fee: q.fee, stable: q.stable, poolID: q.poolID))
        case .bridge(let q, let call):
            return .bridge(BridgeQuote(source: q.source, destination: q.destination, sender: q.sender, recipient: q.recipient, amount: q.amount, expectedDestination: q.expectedDestination, minimumDestination: q.minimumDestination, nativeFee: q.nativeFee, adminFeeBP: q.adminFeeBP, slippageBP: q.slippageBP, sourceOFT: q.sourceOFT, destinationOFT: q.destinationOFT, sendAmount: q.sendAmount, minimumLD: q.minimumLD, quotedAt: Date()), call)
        default: return self
        }
    }
}
public extension RPCClient {
    func nonceState(sender: String) async throws -> (latest: BigUInt, pending: BigUInt) {
        guard Ethereum.validateAddress(sender) else { throw WalletError.invalid(L("message.invalid_account_for_nonce_query")) }
        let latest = try await quantity("eth_getTransactionCount", [.string(sender), .string("latest")])
        let pending = try await quantity("eth_getTransactionCount", [.string(sender), .string("pending")])
        guard latest.bitWidth <= 64, pending.bitWidth <= 64, pending >= latest else { throw WalletError.invalid(L("message.invalid_node_nonce_range_or_ordering")) }; return (latest, pending)
    }
    static func replacementFloor(_ amount: BigUInt) -> BigUInt { max(amount + 1, (amount * 125 + 99) / 100) }
    func prepareReplacement(archive: TransactionArchive, record: TransactionRecord, action: TransactionAction, maxFeeGwei: String? = nil, priorityFeeGwei: String? = nil) async throws -> TransactionPreview {
        try archive.validate()
        guard let original = archive.evm, [.speedUp, .cancel].contains(action), archive.chainID == chain.id,
              original.sender.lowercased() == record.sender.lowercased(), !record.observation.phase.isFinal else { throw WalletError.invalid(L("message.this_record_cannot_be_replaced_or_has_reached_its_confirmation")) }
        try await verifyChain()
        let old = original.transaction, quote = try await feeQuote()
        guard quote.mode == old.mode else { throw WalletError.invalid(L("message.current_fee_mode_differs_from_the_original_verify_the_endpoint")) }
        let floorMax = Self.replacementFloor(old.maxFee), floorTip = old.mode == .legacy ? 0 : Self.replacementFloor(old.maxPriorityFee)
        let maxFee = try maxFeeGwei.map { try Ethereum.parseUnits($0, decimals: 9) } ?? max(floorMax, quote.maxFee)
        let priority = try old.mode == .legacy ? BigUInt(0) : (priorityFeeGwei.map { try Ethereum.parseUnits($0, decimals: 9) } ?? max(floorTip, quote.maxPriorityFee))
        guard maxFee >= floorMax, priority >= floorTip, maxFee >= priority else { throw WalletError.invalid(L("message.replacement_fees_must_increase_by_at_least_25_including_both")) }
        let to = action == .cancel ? archive.sender : old.to, value: BigUInt = action == .cancel ? 0 : old.value, data = action == .cancel ? Data() : old.data
        if action == .cancel {
            let code = try await call("eth_getCode", params: [.string(archive.sender), .string("latest")])
            guard code.string == "0x" else { throw WalletError.invalid(L("message.the_account_has_contract_or_delegation_code_zero_value_self")) }
        }
        let fields = transactionFields(sender: archive.sender, to: to, value: value, data: data, mode: old.mode, maxFee: maxFee, priority: priority)
        let estimate = try await quantity("eth_estimateGas", [.object(fields)])
        let limit = action == .cancel ? max(21_000, (estimate * 120 + 99) / 100) : max(old.gasLimit, (estimate * 120 + 99) / 100)
        let tx = try EVMTransaction(chainID: chain.id, nonce: old.nonce, maxPriorityFee: priority, maxFee: maxFee, gasLimit: limit, to: to, value: value, data: data, mode: old.mode)
        let extra = try await additionalFees(for: tx)
        let ref = EVMReplacementReference(activityID: archive.activityID, groupID: record.groupID, hash: archive.hash, original: old, action: action, minimumMaxFee: floorMax, minimumPriorityFee: floorTip)
        let preview = TransactionPreview(transaction: tx, sender: archive.sender, recipient: action == .cancel ? archive.sender : original.recipient, amount: action == .cancel ? "0" : original.amount, symbol: action == .cancel ? chain.symbol : original.symbol, preparedAt: Date(), token: action == .cancel ? nil : original.token, additionalFees: extra, purpose: action == .cancel ? .transfer : original.purpose, replacement: ref)
        try await revalidate(preview); return preview
    }
    func replayPreview(archive: TransactionArchive, record: TransactionRecord) throws -> TransactionPreview {
        try archive.validate()
        guard let p = archive.evm, archive.chainID == chain.id else { throw WalletError.invalid(L("message.this_is_not_an_evm_archive_for_the_current_chain")) }
        let ref = EVMReplacementReference(activityID: archive.activityID, groupID: record.groupID, hash: archive.hash, original: p.transaction, action: .original, minimumMaxFee: p.transaction.maxFee, minimumPriorityFee: p.transaction.maxPriorityFee)
        return TransactionPreview(transaction: p.transaction, sender: p.sender, recipient: p.recipient, amount: p.amount, symbol: p.symbol, preparedAt: Date(), token: p.token, additionalFees: p.additionalFees, purpose: p.purpose, replacement: ref)
    }
    func reprice(_ preview: TransactionPreview, maxFeeGwei: String, priorityFeeGwei: String) async throws -> TransactionPreview {
        guard !preview.isExpired, preview.transaction.chainID == chain.id else { throw WalletError.invalid(L("message.the_preview_expired_rebuild_it")) }
        let old = preview.transaction, maxFee = try Ethereum.parseUnits(maxFeeGwei, decimals: 9)
        let tip = try old.mode == .legacy ? BigUInt(0) : Ethereum.parseUnits(priorityFeeGwei, decimals: 9)
        guard maxFee > 0, maxFee >= tip else { throw WalletError.invalid(L("message.invalid_fee_rate")) }
        let tx = try EVMTransaction(chainID: old.chainID, nonce: old.nonce, maxPriorityFee: tip, maxFee: maxFee, gasLimit: old.gasLimit, to: old.to, value: old.value, data: old.data, mode: old.mode)
        let result = TransactionPreview(transaction: tx, sender: preview.sender, recipient: preview.recipient, amount: preview.amount, symbol: preview.symbol, preparedAt: Date(), token: preview.token, additionalFees: try await additionalFees(for: tx), purpose: preview.purpose, replacement: preview.replacement)
        try await revalidate(result); return result
    }
    func prepareNonceRepair(sender: String) async throws -> TransactionPreview {
        try await verifyChain(); let state = try await nonceState(sender: sender)
        guard let policy = noncePolicy, let gap = try policy.gap(chainID: chain.id, sender: sender, latest: state.latest, pending: state.pending) else { throw WalletError.invalid(L("message.there_is_no_local_nonce_gap_to_repair")) }
        let code = try await call("eth_getCode", params: [.string(sender), .string("latest")])
        guard code.string == "0x" else { throw WalletError.invalid(L("message.self_transfer_nonce_repair_is_disabled_for_accounts_with_contract")) }
        let fees = try await feeQuote()
        let gas = try await quantity("eth_estimateGas", [.object(transactionFields(sender: sender, to: sender, value: 0, data: Data(), mode: fees.mode, maxFee: fees.maxFee, priority: fees.maxPriorityFee))])
        let tx = try EVMTransaction(chainID: chain.id, nonce: gap, maxPriorityFee: fees.maxPriorityFee, maxFee: fees.maxFee, gasLimit: max(21_000, (gas * 120 + 99) / 100), to: sender, value: 0, mode: fees.mode)
        let ref = EVMReplacementReference(activityID: UUID(), groupID: UUID(), hash: "", original: tx, action: .nonceRepair, minimumMaxFee: fees.maxFee, minimumPriorityFee: fees.maxPriorityFee)
        let p = TransactionPreview(transaction: tx, sender: sender, recipient: sender, amount: "0", symbol: chain.symbol, preparedAt: Date(), token: nil, additionalFees: try await additionalFees(for: tx), purpose: .transfer, replacement: ref)
        try await revalidate(p); return p
    }
}
extension RPCClient {
    func validateReplacement(_ preview: TransactionPreview, latest: BigUInt) async throws {
        guard let ref = preview.replacement, ref.original.chainID == chain.id, preview.transaction.nonce == ref.original.nonce,
              latest <= preview.transaction.nonce, preview.transaction.maxFee >= ref.minimumMaxFee, preview.transaction.maxPriorityFee >= ref.minimumPriorityFee else { throw WalletError.invalid(L("message.the_original_nonce_is_mined_or_replacement_fees_do_not")) }
        let tx = preview.transaction
        if [.cancel, .nonceRepair].contains(ref.action) {
            guard tx.to.lowercased() == preview.sender.lowercased(), tx.value == 0, tx.data.isEmpty else { throw WalletError.invalid(L("message.cancellation_or_gap_repair_must_send_zero_to_the_sender")) }
            let code = try await call("eth_getCode", params: [.string(preview.sender), .string("latest")])
            guard code.string == "0x" else { throw WalletError.invalid(L("message.the_signing_account_now_has_delegation_or_contract_code")) }
        } else {
            guard tx.to == ref.original.to, tx.value == ref.original.value, tx.data == ref.original.data, tx.mode == ref.original.mode, tx.gasLimit >= ref.original.gasLimit else { throw WalletError.invalid(L("message.speed_up_or_rebroadcast_must_preserve_the_original_call_amount")) }
        }
        if ref.action == .nonceRepair {
            let state = try await nonceState(sender: preview.sender)
            guard try noncePolicy?.gap(chainID: chain.id, sender: preview.sender, latest: state.latest, pending: state.pending) == tx.nonce else { throw WalletError.invalid(L("message.the_nonce_gap_changed")) }
        } else {
            guard (try? Data(strictHex: ref.hash).count) == 32 else { throw WalletError.invalid(L("message.original_transaction_hash_missing")) }
            let receipt = try await call("eth_getTransactionReceipt", params: [.string(ref.hash)])
            guard receipt == .null else { throw WalletError.invalid(L("message.the_original_transaction_has_a_receipt_refresh_the_whole_group")) }
        }
        if ref.action == .original {
            guard tx == ref.original else { throw WalletError.invalid(L("message.rebroadcast_requires_the_identical_transaction")) }
        }
        let fields = transactionFields(sender: preview.sender, to: tx.to, value: tx.value, data: tx.data, mode: tx.mode, maxFee: tx.maxFee, priority: tx.maxPriorityFee)
        guard try await quantity("eth_estimateGas", [.object(fields)]) <= tx.gasLimit else { throw WalletError.invalid(L("message.gas_now_required_for_execution_exceeds_the_original_budget")) }
    }
    func transactionFields(sender: String, to: String, value: BigUInt, data: Data, mode: EVMTransactionMode, maxFee: BigUInt, priority: BigUInt) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["from": .string(sender), "to": .string(to), "value": .string(Ethereum.quantity(value)), "data": .string("0x" + data.hexString)]
        if mode == .legacy { fields["gasPrice"] = .string(Ethereum.quantity(maxFee)) }
        else { fields["maxFeePerGas"] = .string(Ethereum.quantity(maxFee)); fields["maxPriorityFeePerGas"] = .string(Ethereum.quantity(priority)) }; return fields
    }
}
