import Foundation
import BigInt

public extension NativeTransferClient {
    func observe(activity: Activity, archive: TransactionArchive? = nil) async throws -> TransactionObservation {
        guard activity.chainID == chain.id else { throw WalletError.invalid(L("message.transaction_observation_network_does_not_match")) }
        if activity.phase == .queued, activity.transaction?.broadcastAttempts == 0 { return TransactionObservation(.queued) }
        if activity.phase == .discarded { return TransactionObservation(.discarded) }
        let plan = archive?.native
        if chain.family != .solana { guard (try? Data(strictHex: activity.hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_transaction_hash")) } }
        switch chain.family {
        case .bitcoin, .litecoin:
            try await verifyUTXONetwork()
            let status: JSONValue
            do { status = try await rest("tx/" + activity.hash + "/status") }
            catch WalletError.http(404) {
                if let plan {
                    for input in plan.payload.inputs {
                        let spend = try await rest("tx/" + input.txid + "/outspend/" + String(input.index))
                        guard spend["spent"] == .bool(false) || spend["spent"] == .bool(true) else { throw WalletError.invalid(L("message.invalid_utxo_spend_status")) }
                        if spend["spent"] == .bool(true), spend["status"]?["confirmed"] == .bool(true) {
                            guard let hash = spend["txid"]?.string, (try? Data(strictHex: hash).count) == 32, hash.lowercased() != activity.hash.lowercased() else { throw WalletError.invalid(L("message.inconsistent_utxo_conflict_status")) }
                            var conflict = try await observeUTXOStatus(spend["status"]!)
                            if conflict.phase == .confirmed { conflict.phase = .conflicted; conflict.winningHash = hash; conflict.detail = L("message.another_hash_spent_the_original_input_on_the_canonical_chain"); return conflict }
                        }
                    }
                }
                return TransactionObservation(.notSeen, detail: L("message.the_node_did_not_find_the_transaction_this_does_not"))
            }
            return try await observeUTXOStatus(status)
        case .solana:
            guard (80...90).contains(activity.hash.count), activity.hash.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }),
                  try await rpc("getGenesisHash", []).string == "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" else { throw WalletError.invalid(L("message.invalid_solana_hash_or_mainnet_identity")) }
            let result = try await rpc("getSignatureStatuses", [.array([.string(activity.hash)]), .object(["searchTransactionHistory": .bool(true)])])
            guard case .array(let values) = result["value"], values.count == 1 else { throw WalletError.invalid(L("message.invalid_solana_status_response")) }
            if values[0] == .null {
                if let plan {
                    let valid = try await rpc("isBlockhashValid", [.string(plan.payload.blockHash), .object(["commitment": .string("finalized")])])
                    guard valid["value"] == .bool(true) || valid["value"] == .bool(false) else { throw WalletError.invalid(L("message.solana_blockhash_validity_is_missing")) }
                    if valid["value"] == .bool(false) { return TransactionObservation(.expired, detail: L("message.the_original_blockhash_is_invalid_so_rebroadcast_is_unavailable_missing")) }
                }
                return TransactionObservation(.notSeen)
            }
            guard let error = values[0]["err"], let level = values[0]["confirmationStatus"]?.string, ["processed", "confirmed", "finalized"].contains(level) else { throw WalletError.invalid(L("message.solana_execution_result_or_confirmation_level_is_missing")) }
            var observation = TransactionObservation(level == "finalized" ? (error == .null ? .confirmed : .failed) : .confirming, detail: L("message.solana_confirmation_level") + level)
            observation.executionSucceeded = error == .null; observation.blockNumber = String(try integer(values[0]["slot"]))
            return observation
        case .aptos:
            let ledger = try await rest(""); guard ledger["chain_id"] == .number(1) else { throw WalletError.invalid(L("message.the_aptos_node_is_not_mainnet")) }
            let tx: JSONValue
            do { tx = try await rest("transactions/by_hash/" + activity.hash) }
            catch WalletError.http(404) {
                if let plan, try integer(ledger["ledger_timestamp"]) / 1_000_000 >= integer(.string(plan.payload.expiration)) { return TransactionObservation(.expired, detail: L("message.the_signature_expired_missing_historical_receipts_do_not_prove_nonpayment")) }
                return TransactionObservation(.notSeen)
            }
            guard tx["hash"]?.string?.lowercased() == activity.hash.lowercased(), activity.transaction == nil || tx["sender"]?.string?.lowercased() == activity.transaction?.sender.lowercased() else { throw WalletError.invalid(L("message.aptos_receipt_hash_or_sender_does_not_match")) }
            if tx["type"] == .string("pending_transaction") { return TransactionObservation(.pending) }
            guard tx["type"] == .string("user_transaction"), tx["success"] == .bool(true) || tx["success"] == .bool(false), try integer(ledger["ledger_version"]) >= integer(tx["version"]) else { throw WalletError.invalid(L("message.aptos_did_not_provide_a_valid_committed_user_transaction")) }
            if let sequence = activity.transaction?.sequence { guard try integer(tx["sequence_number"]) == integer(.string(sequence)) else { throw WalletError.invalid(L("message.aptos_receipt_sequence_does_not_match")) } }
            var result = TransactionObservation(tx["success"] == .bool(true) ? .confirmed : .failed, detail: L("message.aptos_committed_version") + String(try integer(tx["version"])))
            result.executionSucceeded = tx["success"] == .bool(true); result.executionFee = String(try integer(tx["gas_used"]) * integer(tx["gas_unit_price"])); return result
        case .tron:
            try await TronContractClient(transport: transport, chain: chain, isolation: isolation).verifyChain()
            let confirmed = try await rest("walletsolidity/gettransactioninfobyid", body: .object(["value": .string(activity.hash)]))
            if confirmed == .object([:]) {
                let pending = try await rest("wallet/gettransactionbyid", body: .object(["value": .string(activity.hash)]))
                if pending != .object([:]) { guard pending["txID"]?.string?.lowercased() == activity.hash.lowercased() else { throw WalletError.invalid(L("message.tron_transaction_id_does_not_match")) }; return TransactionObservation(.pending) }
                if let plan {
                    let block = try await rest("walletsolidity/getnowblock", body: .object([:]))
                    if try integer(block["block_header"]?["raw_data"]?["timestamp"]) >= integer(.string(plan.payload.expiration)) { return TransactionObservation(.expired, detail: L("message.solidified_chain_time_exceeds_signature_validity_missing_receipts_still_do")) }
                }
                return TransactionObservation(.notSeen)
            }
            guard confirmed["id"]?.string?.lowercased() == activity.hash.lowercased(), try integer(confirmed["blockNumber"]) > 0 else { throw WalletError.invalid(L("message.invalid_tron_solidified_receipt_hash_or_height")) }
            let tx = try await rest("walletsolidity/gettransactionbyid", body: .object(["value": .string(activity.hash)]))
            guard tx["txID"]?.string?.lowercased() == activity.hash.lowercased(), case .array(let returns) = tx["ret"], returns.count == 1, let outcome = returns[0]["contractRet"]?.string else { throw WalletError.invalid(L("message.tron_solidified_transaction_is_missing_its_execution_result")) }
            guard case .array(let contracts) = tx["raw_data"]?["contract"], contracts.count == 1, let type = contracts[0]["type"]?.string,
                  ["TransferContract", "TriggerSmartContract"].contains(type) else { throw WalletError.invalid(L("message.tron_solidified_transaction_type_is_invalid_or_unsupported")) }
            if let plan, let call = plan.contract {
                let value = contracts[0]["parameter"]?["value"]
                guard type == "TriggerSmartContract", plan.sender == activity.transaction?.sender,
                      try TronAddress.fromRPC(value?["owner_address"]?.string) == plan.sender,
                      try TronAddress.fromRPC(value?["contract_address"]?.string) == call.contract,
                      value?["data"]?.string?.lowercased() == call.data.hexString,
                      try integer(value?["call_value"] ?? .number(0)) == call.callValue else {
                    throw WalletError.invalid(L("message.tron_solidified_transaction_differs_from_the_locally_approved_call"))
                }
            }
            var succeeded = outcome == "SUCCESS"
            if let status = confirmed["result"] { succeeded = succeeded && status == .string("SUCESS") }
            if type == "TriggerSmartContract", succeeded {
                guard let vm = confirmed["receipt"]?["result"]?.string else { throw WalletError.invalid(L("message.tron_solidified_contract_receipt_is_missing_its_execution_result")) }
                succeeded = vm == "SUCCESS"
                if succeeded {
                    guard case .array(let outputs) = confirmed["contractResult"], outputs.count == 1, let encoded = outputs[0].string, let output = try? Data(strictHex: encoded) else { throw WalletError.invalid(L("message.tron_contract_receipt_is_missing_valid_return_data")) }
                    if let data = contracts[0]["parameter"]?["value"]?["data"]?.string, data.lowercased().hasPrefix("095ea7b3"), output.count == 32, output.allSatisfy({ $0 == 0 }) { succeeded = false }
                }
            }
            var result = TransactionObservation(succeeded ? .confirmed : .failed, detail: L("message.the_tron_solidity_node_returned_an_execution_receipt"))
            result.executionSucceeded = succeeded; result.blockNumber = String(try integer(confirmed["blockNumber"]))
            if let fee = confirmed["fee"] { result.executionFee = String(try integer(fee)) }; return result
        case .cosmos:
            guard let profile = activity.transaction?.profileID ?? chain.profileKeys.first, let identifier = CosmosTransferConfiguration.chainIdentifiers[profile] else { throw WalletError.invalid(L("message.transaction_status_adaptation_is_unavailable_for_this_cosmos_network")) }
            let head = try await cosmosHead(identifier: identifier), tx: JSONValue
            do { tx = try await rest("cosmos/tx/v1beta1/txs/" + activity.hash) }
            catch WalletError.http(404) {
                if let plan, head >= (try integer(.string(plan.payload.expiration))) { return TransactionObservation(.expired, detail: L("message.the_timeout_height_passed_historical_indexing_returned_no_receipt_verify")) }; return TransactionObservation(.notSeen)
            }
            guard let receipt = tx["tx_response"], receipt["txhash"]?.string?.uppercased() == activity.hash.uppercased(), try integer(receipt["height"]) > 0, try integer(receipt["height"]) <= head else { throw WalletError.invalid(L("message.invalid_cosmos_receipt_hash_or_height")) }
            let succeeded = try integer(receipt["code"]) == 0
            var result = TransactionObservation(succeeded ? .confirmed : .failed, detail: L("message.the_cosmos_node_reports_a_committed_execution_result"))
            result.blockNumber = String(try integer(receipt["height"])); result.executionSucceeded = succeeded; return result
        default: throw WalletError.invalid(L("message.transaction_status_management_is_unsupported_on_this_network"))
        }
    }
    func validateReplay(archive: TransactionArchive) async throws {
        try archive.validate()
        guard let plan = archive.native, archive.chainID == chain.id, plan.family == chain.family, let activity = archive.activity else { throw WalletError.invalid(L("message.signed_transaction_material_for_the_current_network_is_missing")) }
        // A queued archive has never been sent, but its blockhash / timeout may
        // still have expired while the app was closed. Always query the chain.
        var queried = activity
        if queried.phase == .queued { queried.transaction?.observation = TransactionObservation(.broadcastUnknown); queried.transaction?.broadcastAttempts = 1 }
        let observation = try await observe(activity: queried, archive: archive)
        guard !observation.phase.isFinal, observation.phase != .confirming else { throw WalletError.invalid(L("message.confirmed_expired_or_confirming_transactions_cannot_be_rebroadcast_refresh_their")) }
        if [.bitcoin, .litecoin].contains(chain.family) {
            _ = try inspectUTXOArchive(archive)
            for input in plan.payload.inputs {
                let spent = try await rest("tx/" + input.txid + "/outspend/" + String(input.index))
                guard spent["spent"] == .bool(false) || (spent["spent"] == .bool(true) && spent["txid"]?.string?.lowercased() == archive.hash.lowercased()) else { throw WalletError.invalid(L("message.another_hash_uses_an_original_input_not_rebroadcast")) }
            }
        }
        if chain.family == .aptos {
            let account = try await rest("accounts/" + plan.sender)
            guard try integer(account["sequence_number"]) == integer(.string(plan.payload.nonce)) else { throw WalletError.invalid(L("message.the_original_aptos_sequence_was_used_query_the_old_transaction")) }
        }
    }
    func broadcastArchive(_ archive: TransactionArchive) async throws -> String {
        try archive.validate()
        guard let plan = archive.native, plan.family == chain.family, plan.chainID == chain.id else { throw WalletError.invalid(L("message.signed_transaction_network_does_not_match")) }
        return try await broadcast(NativeSignedTransfer(hash: archive.hash, family: chain.family, chainID: chain.id, encoded: archive.signedPayload))
    }
}
extension NativeTransferClient {
    func verifyUTXONetwork() async throws {
        guard [.bitcoin, .litecoin].contains(chain.family) else { throw WalletError.invalid(L("message.this_is_not_a_utxo_network")) }
        let value = String(decoding: try await raw("block-height/0"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == (chain.family == .litecoin ? Litecoin.mainnetGenesis : "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f") else { throw WalletError.invalid(L("message.utxo_node_genesis_does_not_match")) }
    }
    func observeUTXOStatus(_ status: JSONValue) async throws -> TransactionObservation {
        guard status["confirmed"] == .bool(true) || status["confirmed"] == .bool(false) else { throw WalletError.invalid(L("message.utxo_status_is_missing_confirmed")) }
        if status["confirmed"] == .bool(false) { return TransactionObservation(.pending) }
        let height = try integer(status["block_height"])
        guard height > 0, let hash = status["block_hash"]?.string, (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_utxo_receipt_block")) }
        let canonical = String(decoding: try await raw("block-height/" + String(height)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? Data(strictHex: canonical).count) == 32 else { throw WalletError.invalid(L("message.invalid_utxo_canonical_block_hash")) }
        if canonical.lowercased() != hash.lowercased() { return TransactionObservation(.reorged) }
        let tipText = String(decoding: try await raw("blocks/tip/height"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = try integer(.string(tipText)); guard tip >= height, let count = UInt64(exactly: tip - height + 1) else { throw WalletError.invalid(L("message.the_utxo_chain_head_is_behind_the_receipt")) }
        var result = TransactionObservation(count >= 6 ? .confirmed : .confirming)
        result.blockNumber = String(height); result.blockHash = hash.lowercased(); result.confirmations = count; result.requiredConfirmations = 6; result.executionSucceeded = true; return result
    }
}
