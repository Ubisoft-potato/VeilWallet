import Foundation
import BigInt

public struct NativeArchivedPlan: Codable, Sendable {
    public let chainID: UInt64
    public let profileID: String
    public let family: NetworkFamily
    public let sender: String
    public let recipient: String
    public let amount: BigUInt
    public let feeBudget: BigUInt
    public let preparedAt: Date
    let payload: NativeTransferPayload
    let unsigned: String
    public let contract: TronInvocation?
    public var payloadMemo: String { payload.memo }
    public init(_ plan: NativeTransferPlan) {
        chainID = plan.chainID; profileID = plan.profileID; family = plan.family; sender = plan.sender; recipient = plan.recipient; amount = plan.amount; feeBudget = plan.feeBudget; preparedAt = plan.preparedAt; payload = plan.payload; unsigned = plan.unsigned; contract = plan.contract
    }
    var restored: NativeTransferPlan { .init(chainID: chainID, profileID: profileID, family: family, sender: sender, recipient: recipient, amount: amount, feeBudget: feeBudget, preparedAt: preparedAt, details: [], payload: payload, unsigned: unsigned, contract: contract) }
    public func sameTransaction(as plan: NativeTransferPlan) -> Bool { restored.sameTransaction(as: plan) }
}
public struct MoneroArchivedPlan: Codable, Sendable {
    public let profileID: String
    public let recipient: String
    public let amount: BigUInt
    public let fee: BigUInt
}
/// Encrypted locally, never logged or exported to an indexer. Keeps the exact
/// authorized signed bytes so a retry cannot become a second payment.
public struct TransactionArchive: Codable, Sendable {
    public let version: Int
    public let activityID: UUID
    public let walletID: UUID
    public let chainID: UInt64
    public let sender: String
    public let hash: String
    public let evm: TransactionPreview?
    public let native: NativeArchivedPlan?
    public let monero: MoneroArchivedPlan?
    public private(set) var signedPayload: String
    public var activity: Activity?
    public init(activityID: UUID, walletID: UUID, preview: TransactionPreview, raw: Data) throws {
        version = 1; self.activityID = activityID; self.walletID = walletID; chainID = preview.transaction.chainID; sender = preview.sender; hash = "0x" + raw.keccak256.hexString; evm = preview; native = nil; monero = nil; signedPayload = "0x" + raw.hexString
        try validate()
    }
    public init(activityID: UUID, walletID: UUID, plan: NativeTransferPlan, signed: NativeSignedTransfer) throws {
        version = 1; self.activityID = activityID; self.walletID = walletID; chainID = plan.chainID; sender = plan.sender; hash = signed.hash; evm = nil; native = NativeArchivedPlan(plan); monero = nil; signedPayload = signed.encoded
        try validate()
    }
    public init(activityID: UUID, chainID: UInt64, profileID: String, proposal: MoneroProposal) throws {
        version = 1; self.activityID = activityID; walletID = proposal.walletID; self.chainID = chainID; sender = proposal.sender; hash = proposal.hash; evm = nil; native = nil; monero = .init(profileID: profileID, recipient: proposal.recipient, amount: proposal.amount, fee: proposal.fee); signedPayload = proposal.metadata; try validate()
    }
    public func validate() throws {
        let discarded = activity?.phase == .discarded && activity?.transaction?.broadcastAttempts == 0
        guard version == 1, signedPayload.utf8.count <= 2_000_000, !signedPayload.isEmpty || discarded, [evm != nil, native != nil, monero != nil].filter({ $0 }).count == 1 else { throw WalletError.invalid(L("message.invalid_local_transaction_archive_format")) }
        if let activity { guard activity.id == activityID, activity.walletID == walletID, activity.chainID == chainID, activity.hash.lowercased() == hash.lowercased(), activity.transaction?.sender == sender else { throw WalletError.invalid(L("message.the_transaction_journal_does_not_match_its_archived_envelope")) } }
        if let preview = evm {
            let tx = preview.transaction
            if !discarded { try tx.verifySigned(Data(strictHex: signedPayload), sender: sender) }
            let matchingHash = discarded ? true : "0x" + (try Data(strictHex: signedPayload)).keccak256.hexString == hash
            guard tx.chainID == chainID, preview.sender == sender, Ethereum.validateAddress(sender), tx.nonce.bitWidth <= 64,
                  try EVMTransaction(chainID: tx.chainID, nonce: tx.nonce, maxPriorityFee: tx.maxPriorityFee, maxFee: tx.maxFee, gasLimit: tx.gasLimit, to: tx.to, value: tx.value, data: tx.data, mode: tx.mode) == tx,
                  matchingHash else { throw WalletError.invalid(L("message.evm_archive_signature_hash_or_parameters_do_not_match")) }
            if let call = preview.purpose.invocation {
                guard try ContractInvocation(contract: call.contract, signature: call.signature, arguments: call.arguments, nativeValue: call.nativeValue) == call,
                      tx.to.lowercased() == call.contract.lowercased(), tx.value == call.nativeValue, tx.data == call.data else { throw WalletError.invalid(L("message.archived_calldata_does_not_match_the_approved_intent")) }
            } else if let token = preview.token {
                guard tx.to.lowercased() == token.contract.lowercased(), tx.value == 0, try Ethereum.transferData(to: preview.recipient, amount: Ethereum.parseUnits(preview.amount, decimals: token.decimals)) == tx.data else { throw WalletError.invalid(L("message.archived_token_transfer_does_not_match")) }
            } else {
                guard tx.data.isEmpty, tx.to.lowercased() == preview.recipient.lowercased(), try Ethereum.parseUnits(preview.amount, decimals: Chain.defaults.first(where: { $0.id == chainID })?.decimals ?? 18) == tx.value else { throw WalletError.invalid(L("message.archived_native_transfer_does_not_match")) }
            }
        } else if let native {
            let recipient = native.family == .litecoin ? try Litecoin.addressInfo(native.recipient).canonicalAddress : native.recipient
            guard native.chainID == chainID, native.sender == sender, native.payload.from == sender, native.payload.to == recipient,
                  native.payload.amount == String(native.amount), !native.unsigned.isEmpty else { throw WalletError.invalid(L("message.the_non_evm_archive_does_not_match_its_approved_preview")) }
        } else if let monero {
            guard let profile = AccountProfile.find(monero.profileID), profile.family == .monero, MultichainCrypto.validateAddress(sender, profile: profile), MultichainCrypto.validateAddress(monero.recipient, profile: profile), monero.amount > 0, monero.fee > 0, (try? Data(strictHex: hash).count) == 32, discarded || (try? Data(strictHex: signedPayload).isEmpty) == false else { throw WalletError.invalid(L("message.invalid_xmr_signed_material_or_account")) }
        }
    }
    mutating func discardSignature() throws {
        guard activity?.transaction?.broadcastAttempts == 0, activity?.phase == .queued else { throw WalletError.invalid(L("message.the_archive_records_a_broadcast_attempt_and_cannot_be_discarded")) }
        signedPayload = ""; activity?.transaction?.observation = TransactionObservation(.discarded); activity?.status = TransactionPhase.discarded.label; try validate()
    }
}
public struct EVMReplacementReference: Codable, Sendable {
    public let activityID: UUID
    public let groupID: UUID
    public let hash: String
    public let original: EVMTransaction
    public let action: TransactionAction
    public let minimumMaxFee: BigUInt
    public let minimumPriorityFee: BigUInt
}
