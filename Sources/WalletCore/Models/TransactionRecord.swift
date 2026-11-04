import Foundation
import BigInt

public enum TransactionPhase: String, Codable, CaseIterable, Sendable {
    case queued, broadcastUnknown, submitted, pending, notSeen, confirming, confirmed, failed, cancelled, replaced, nonceConsumed, expired, conflicted, reorged, discarded
    public var label: String { WalletLocalization.legacy("phase." + rawValue) }
    public var displayLabel: String { LK(label) }
    public var isFinal: Bool { [.confirmed, .failed, .cancelled, .replaced, .expired, .conflicted, .discarded].contains(self) }
}
public enum TransactionAction: String, Codable, Sendable {
    case original, speedUp, cancel, nonceRepair, cpfp
    public var label: String { switch self { case .original: return L("message.original_transaction"); case .speedUp: return L("message.speed_up"); case .cancel: return L("action.cancel"); case .nonceRepair: return L("message.repair_nonce_gap"); case .cpfp: return L("message.cpfp_child_transaction") } }
}
public struct TransactionObservation: Codable, Sendable {
    public var phase: TransactionPhase
    public var checkedAt: Date
    public var blockNumber: String?
    public var blockHash: String?
    public var confirmations: UInt64?
    public var requiredConfirmations: UInt64?
    public var executionSucceeded: Bool?
    public var executionFee: String?
    public var winningHash: String?
    public var detail: String?
    public init(_ phase: TransactionPhase, detail: String? = nil) { self.phase = phase; checkedAt = Date(); self.detail = detail }
}
public struct AssetReservation: Codable, Sendable {
    public let contract: String
    public let amount: String
    public init(contract: String, amount: BigUInt) { self.contract = contract.lowercased(); self.amount = String(amount) }
}
public struct TransactionRecord: Codable, Sendable {
    public let groupID: UUID
    public let action: TransactionAction
    public let sender: String
    public let profileID: String
    public let sequence: String?
    public let nativeCost: String
    public let tokenSpends: [AssetReservation]
    public let spentOutputs: [String]
    public let parentID: UUID?
    public var observation: TransactionObservation
    public var broadcastAttempts: Int
    public var lastBroadcastAt: Date?
    public init(groupID: UUID, action: TransactionAction = .original, sender: String, profileID: String, sequence: String?, nativeCost: BigUInt, tokenSpends: [AssetReservation] = [], spentOutputs: [String] = [], parentID: UUID? = nil, phase: TransactionPhase = .queued) {
        self.groupID = groupID; self.action = action; self.sender = sender; self.profileID = profileID; self.sequence = sequence; self.nativeCost = String(nativeCost); self.tokenSpends = tokenSpends; self.spentOutputs = spentOutputs; self.parentID = parentID
        observation = TransactionObservation(phase); broadcastAttempts = 0
    }
    public static func evm(_ preview: TransactionPreview, groupID: UUID, action: TransactionAction = .original, parentID: UUID? = nil) -> TransactionRecord {
        var spends: [AssetReservation] = []
        if let token = preview.token, let amount = try? Ethereum.parseUnits(preview.amount, decimals: token.decimals) { spends = [.init(contract: token.contract, amount: amount)] }
        if case .swap(let q) = preview.purpose, let token = q.input { spends = [.init(contract: token.contract, amount: q.amountIn)] }
        if case .bridge(let q, _) = preview.purpose { spends = [.init(contract: q.source.tokenAddress, amount: q.amount)] }
        return .init(groupID: groupID, action: action, sender: preview.sender, profileID: "evm", sequence: String(preview.transaction.nonce), nativeCost: preview.transaction.value + preview.totalFeeBudget, tokenSpends: spends, parentID: parentID)
    }
    public static func native(_ plan: NativeTransferPlan, groupID: UUID, action: TransactionAction = .original, parentID: UUID? = nil) -> TransactionRecord {
        let sequence = [.aptos, .cosmos].contains(plan.family) ? plan.payload.nonce : nil
        return .init(groupID: groupID, action: action, sender: plan.sender, profileID: plan.profileID, sequence: sequence, nativeCost: plan.amount + plan.feeBudget, spentOutputs: plan.payload.inputs.map { $0.txid.lowercased() + ":" + String($0.index) }, parentID: parentID)
    }
    public var maySubmitAgain: Bool { !observation.phase.isFinal && (lastBroadcastAt.map { Date().timeIntervalSince($0) >= 30 } ?? true) }
}
public extension Activity {
    var phase: TransactionPhase? { transaction?.observation.phase }
    var effectiveHash: String { transaction?.observation.winningHash ?? hash }
    var statusLabel: String { transaction?.observation.phase.displayLabel ?? LK(status) }
    var isUnresolved: Bool {
        if let transaction { return !transaction.observation.phase.isFinal }
        if [WalletLocalization.legacy("receipt.confirmed"), WalletLocalization.legacy("receipt.failed")].contains(status) { return false }
        return !(TransactionPhase.allCases.first(where: { $0.label == status })?.isFinal ?? false)
    }
}

/// Immutable local view, recreated for every new prepare/sign operation.
public struct EVMNoncePolicy: Sendable {
    public let activities: [Activity]
    public init(activities: [Activity]) { self.activities = activities }
    private func records(chainID: UInt64, sender: String, latest: BigUInt) throws -> [TransactionRecord] {
        try activities.filter { $0.chainID == chainID }.compactMap { activity in
            guard let record = activity.transaction, record.observation.phase != .discarded, record.profileID == "evm", record.sender.lowercased() == sender.lowercased(), let text = record.sequence else { return nil }
            guard let nonce = BigUInt(text), nonce.bitWidth <= 64 else { throw WalletError.invalid(L("message.invalid_local_nonce_record")) }
            return nonce >= latest ? record : nil
        }
    }
    public func next(chainID: UInt64, sender: String, latest: BigUInt, pending: BigUInt) throws -> BigUInt {
        guard pending >= latest, pending.bitWidth <= 64 else { throw WalletError.invalid(L("message.the_node_s_pending_nonce_is_below_its_confirmed_nonce")) }
        let records = try records(chainID: chainID, sender: sender, latest: latest)
        let used = Set(records.compactMap { $0.sequence.flatMap { BigUInt($0) } })
        let next = max(pending, (used.max().map { $0 + 1 } ?? pending))
        guard next < BigUInt(UInt64.max), next - pending <= 64 else { throw WalletError.invalid(L("message.the_pending_nonce_queue_exceeds_64_entries_resolve_existing_transactions")) }
        var cursor = pending
        while cursor < next {
            guard used.contains(cursor) else { throw WalletError.invalid(L("message.the_local_nonce_queue_has_a_gap_verify_or_repair")) }; cursor += 1
        }
        return next
    }
    public func gap(chainID: UInt64, sender: String, latest: BigUInt, pending: BigUInt) throws -> BigUInt? {
        guard pending >= latest, pending.bitWidth <= 64 else { throw WalletError.invalid(L("message.invalid_node_nonce")) }
        let used = Set(try records(chainID: chainID, sender: sender, latest: latest).compactMap { $0.sequence.flatMap { BigUInt($0) } })
        guard let maximum = used.max(), maximum >= pending, maximum - pending <= 64 else { return nil }
        var cursor = pending
        while cursor <= maximum { if !used.contains(cursor) { return cursor }; cursor += 1 }; return nil
    }
    public func reserved(chainID: UInt64, sender: String, latest: BigUInt, excludingNonce: BigUInt? = nil, token: String? = nil) throws -> BigUInt {
        var maximums: [String: BigUInt] = [:]
        for record in try records(chainID: chainID, sender: sender, latest: latest) {
            guard let nonce = record.sequence, BigUInt(nonce) != excludingNonce else { continue }
            let value: BigUInt
            if let token {
                let amounts = record.tokenSpends.filter { $0.contract == token.lowercased() }
                guard amounts.allSatisfy({ BigUInt($0.amount) != nil }) else { throw WalletError.invalid(L("message.invalid_local_token_reservation")) }
                value = amounts.reduce(0) { $0 + (BigUInt($1.amount) ?? 0) }
            } else { guard let amount = BigUInt(record.nativeCost) else { throw WalletError.invalid(L("message.invalid_local_fee_reservation")) }; value = amount }
            maximums[nonce] = max(maximums[nonce] ?? 0, value)
        }
        return maximums.values.reduce(0, +)
    }
}
