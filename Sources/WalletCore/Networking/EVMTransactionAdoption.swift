import Foundation
import BigInt

public extension RPCClient {
    /// Recover legacy local records by hash, without an address-history indexer.
    /// Reconstruct signed bytes and recover the signer before trusting RPC fields.
    func adopt(activity: Activity, sender: String) async throws -> (TransactionArchive, TransactionRecord) {
        guard activity.chainID == chain.id, Ethereum.validateAddress(sender), (try? Data(strictHex: activity.hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_legacy_transaction_network_account_or_hash")) }
        try await verifyChain()
        let result = try await call("eth_getTransactionByHash", params: [.string(activity.hash)])
        guard result != .null, result["hash"]?.string?.lowercased() == activity.hash.lowercased(), result["from"]?.string?.lowercased() == sender.lowercased(), let to = result["to"]?.string, Ethereum.validateAddress(to) else { throw WalletError.invalid(L("message.the_node_did_not_return_an_adoptable_transaction_for_this")) }
        func uint(_ name: String) throws -> BigUInt {
            guard let text = result[name]?.string else { throw WalletError.invalid(L("message.node_transaction_is_missing_required_fields")) }; return try Ethereum.decodeQuantity(text)
        }
        let type = try uint("type"), mode: EVMTransactionMode
        guard type == 0 || type == 2 else { throw WalletError.invalid(L("message.this_historical_transaction_type_is_query_only_replacement_is_unsupported")) }; mode = type == 0 ? .legacy : .eip1559
        if let declared = result["chainId"]?.string { guard try Ethereum.decodeQuantity(declared) == BigUInt(chain.id) else { throw WalletError.invalid(L("message.transaction_signing_chain_id_does_not_match")) } }
        if mode == .eip1559 { guard result["accessList"] == .array([]) else { throw WalletError.invalid(L("message.historical_access_list_transactions_cannot_be_adopted_yet")) } }
        guard let input = result["input"]?.string else { throw WalletError.invalid(L("message.historical_transaction_is_missing_calldata")) }
        let tx = try EVMTransaction(chainID: chain.id, nonce: uint("nonce"), maxPriorityFee: mode == .legacy ? 0 : uint("maxPriorityFeePerGas"), maxFee: uint(mode == .legacy ? "gasPrice" : "maxFeePerGas"), gasLimit: uint("gas"), to: to, value: uint("value"), data: Data(strictHex: input), mode: mode)
        let v = try uint("v"), recovery: UInt8
        if mode == .legacy {
            let base = BigUInt(chain.id) * 2 + 35; guard v == base || v == base + 1 else { throw WalletError.invalid(L("message.this_is_not_an_eip_155_transaction_on_the_current")) }; recovery = UInt8(v - base)
        } else { guard v <= 1 else { throw WalletError.invalid(L("message.invalid_type_2_transaction_recovery_bit")) }; recovery = UInt8(v) }
        let r = try uint("r"), s = try uint("s"), raw = try tx.serialized(r: r, s: s, recovery: recovery)
        let pub = try Secp256k1.recoverPublicKey(hash: tx.signingHash, r: ContractABI.word(r), s: ContractABI.word(s), recovery: recovery)
        let recovered = "0x" + Data(pub.dropFirst()).keccak256.suffix(20).hexString
        guard recovered.lowercased() == sender.lowercased(), "0x" + raw.keccak256.hexString == activity.hash.lowercased() else { throw WalletError.invalid(L("message.historical_signature_hash_and_sender_do_not_match")) }
        // Existing contract calldata cannot be safely reclassified as a known
        // typed intent. This version permits receipt queries for those records.
        guard tx.data.isEmpty else { throw WalletError.invalid(L("message.this_legacy_contract_transaction_lacks_locally_typed_intent_only_receipt")) }
        let preview = TransactionPreview(transaction: tx, sender: Ethereum.checksumAddress(sender), recipient: Ethereum.checksumAddress(to), amount: Ethereum.formatUnits(tx.value, decimals: chain.decimals, precision: chain.decimals), symbol: chain.symbol, preparedAt: Date(), token: nil, additionalFees: try await additionalFees(for: tx), purpose: .transfer)
        let archive = try TransactionArchive(activityID: activity.id, walletID: activity.walletID, preview: preview, raw: raw)
        var record = TransactionRecord.evm(preview, groupID: activity.id); record.observation = TransactionObservation(.broadcastUnknown); record.broadcastAttempts = 1; record.lastBroadcastAt = activity.date
        return (archive, record)
    }
}
