import Foundation

public enum DexApprovalRequirement: String, Sendable {
    case none, reset, token, permit2
    public var title: String {
        switch self {
        case .none: return L("message.swap")
        case .reset: return L("message.revoke_old_approval_first")
        case .token: return L("message.approve_this_payment_amount")
        case .permit2: return L("message.approve_short_lived_router_allowance")
        }
    }
    public var detail: String {
        switch self {
        case .none: return L("message.allowance_is_sufficient_the_next_transaction_is_the_swap")
        case .reset: return L("message.the_existing_nonzero_allowance_is_insufficient_sign_a_reset_to")
        case .token: return L("message.approve_only_this_input_amount_after_confirmation_requote_and_sign")
        case .permit2: return L("message.token_allowance_is_sufficient_a_separate_short_lived_permit2_router")
        }
    }
}

public extension DexQuote {
    /// Pending zero-resets must also block continuation, even while the old
    /// allowance is still visible. Match the typed archived intent on reopening.
    func matchesApproval(_ call: ContractInvocation) -> Bool {
        guard let input else { return false }
        if call.contract.lowercased() == input.contract.lowercased(), call.signature == "approve(address,uint256)" {
            return call.arguments.first?.lowercased() == approvalSpender.lowercased()
        }
        if approvalSpender.lowercased() == EVMVenueClient.permit2, call.contract.lowercased() == EVMVenueClient.permit2,
           call.signature == "approve(address,address,uint160,uint48)", call.arguments.count == 4 {
            return call.arguments[0].lowercased() == input.contract.lowercased() && call.arguments[1].lowercased() == invocation.contract.lowercased()
        }
        return false
    }
}

/// Continuation is based on a freshly observed canonical receipt, not allowance
/// alone. A missing receipt or consumed nonce never means an approval succeeded.
public enum DexApprovalProgress: Equatable, Sendable {
    case waiting(String)
    case ready
    case stopped(String)

    public static func resolveTron(hash: String, activities: [Activity], walletID: UUID, sender: String, chainID: UInt64 = TronAddress.chainID) -> Self {
        guard TronNetwork.isTron(chainID),
              let item = activities.first(where: { $0.hash.lowercased() == hash.lowercased() && $0.walletID == walletID && $0.chainID == chainID }),
              let record = item.transaction, record.profileID == "tron", record.sender == sender, record.action == .original else {
            return .waiting(L("message.no_approval_record_was_found_for_the_current_tron_account"))
        }
        let result = record.observation
        if [.failed, .cancelled, .expired, .conflicted, .discarded].contains(result.phase) { return .stopped(result.phase.displayLabel + L("message.this_swap_has_not_been_sent")) }
        guard result.phase == .confirmed, result.executionSucceeded == true, let height = result.blockNumber.flatMap(UInt64.init), height > 0 else {
            return .waiting(result.phase.displayLabel + L("message.waiting_for_solidified_execution_success_the_swap_has_not_been"))
        }
        return .ready
    }

    public static func resolve(hash: String, activities: [Activity], walletID: UUID, chainID: UInt64, sender: String) -> Self {
        guard let original = activities.first(where: { $0.hash.lowercased() == hash.lowercased() && $0.walletID == walletID && $0.chainID == chainID }),
              let record = original.transaction, record.profileID == "evm", record.sender.lowercased() == sender.lowercased() else {
            return .waiting(L("message.no_approval_record_was_found_for_this_account_verify_the"))
        }
        let effective: Activity
        if let winner = record.observation.winningHash {
            guard let item = activities.first(where: { $0.hash.lowercased() == winner.lowercased() && $0.walletID == walletID && $0.chainID == chainID && $0.transaction?.groupID == record.groupID && $0.transaction?.sequence == record.sequence && $0.transaction?.profileID == record.profileID && $0.transaction?.sender.lowercased() == sender.lowercased() }) else {
                return .waiting(L("message.the_approval_was_replaced_but_its_replacement_outcome_remains_unverified"))
            }
            effective = item
        } else { effective = original }
        guard let outcome = effective.transaction?.observation else { return .waiting(L("message.the_approval_receipt_remains_unverified")) }
        if [.failed, .cancelled, .expired, .conflicted, .discarded].contains(outcome.phase) {
            return .stopped(outcome.phase.displayLabel + L("message.this_swap_has_not_been_sent"))
        }
        let required: UInt64 = chainID == 56 ? 15 : 12
        guard outcome.phase == .confirmed, outcome.executionSucceeded == true,
              outcome.requiredConfirmations == required, (outcome.confirmations ?? 0) >= required,
              outcome.blockHash != nil, outcome.blockNumber != nil,
              [.original, .speedUp].contains(effective.transaction?.action) else {
            return .waiting(outcome.phase.displayLabel + L("message.the_swap_has_not_been_sent_verify_again_later"))
        }
        return .ready
    }
}

public extension TronDexQuote {
    func matchesApproval(_ call: TronInvocation) -> Bool {
        guard let input, call.callValue == 0 else { return false }
        let spender = mode == .v2 ? TronDexClient.v2Router : TronDexClient.permit2
        if call.contract == input.contract, call.signature == "approve(address,uint256)", call.arguments.count == 2 {
            return call.arguments[0].lowercased() == (try? TronAddress.evm(spender))?.lowercased()
        }
        if mode == .smart, call.contract == TronDexClient.permit2, call.signature == "approve(address,address,uint160,uint48)", call.arguments.count == 4 {
            return call.arguments[0].lowercased() == (try? TronAddress.evm(input.contract))?.lowercased() &&
                   call.arguments[1].lowercased() == (try? TronAddress.evm(TronDexClient.universalRouter))?.lowercased()
        }
        return false
    }
}
