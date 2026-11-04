import Foundation

public extension NativeTransferClient {
    func receipt(hash: String) async throws -> String {
        if chain.family != .solana { guard (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_transaction_hash_d7e78dc9")) } }
        switch chain.family {
        case .cosmos:
            let result = try await rest("cosmos/tx/v1beta1/txs/" + hash)
            guard let response = result["tx_response"], response["txhash"]?.string?.uppercased() == hash.uppercased(), try integer(response["height"]) > 0 else { throw WalletError.invalid(L("message.the_cosmos_node_has_not_returned_a_valid_block_receipt")) }
            return try integer(response["code"]) == 0 ? WalletLocalization.legacy("receipt.confirmed") : WalletLocalization.legacy("receipt.failed")
        case .bitcoin, .litecoin:
            let result = try await rest("tx/" + hash + "/status")
            guard let confirmed = result["confirmed"], confirmed == .bool(true) || confirmed == .bool(false) else { throw WalletError.invalid(L("message.the_utxo_node_returned_an_invalid_transaction_status")) }; return confirmed == .bool(true) ? WalletLocalization.legacy("receipt.confirmed") : WalletLocalization.legacy("receipt.pending")
        case .solana:
            guard (80...90).contains(hash.count), hash.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }) else { throw WalletError.invalid(L("message.invalid_solana_transaction_signature")) }
            let result = try await rpc("getSignatureStatuses", [.array([.string(hash)]), .object(["searchTransactionHistory": .bool(true)])])
            guard case .array(let values) = result["value"], values.count == 1 else { throw WalletError.invalid(L("message.the_solana_node_returned_an_invalid_signature_status")) }
            if values[0] == .null { return WalletLocalization.legacy("receipt.pending") }
            guard let error = values[0]["err"] else { throw WalletError.invalid(L("message.solana_receipt_is_missing_its_error_status")) }; if error != .null { return WalletLocalization.legacy("receipt.failed") }
            guard let status = values[0]["confirmationStatus"]?.string else { throw WalletError.invalid(L("message.solana_receipt_is_missing_its_confirmation_level")) }
            return ["confirmed", "finalized"].contains(status) ? WalletLocalization.legacy("receipt.confirmed") : WalletLocalization.legacy("receipt.pending")
        case .aptos:
            let result = try await rest("transactions/by_hash/" + hash)
            if result["type"]?.string == "pending_transaction" { return WalletLocalization.legacy("receipt.pending") }
            guard let success = result["success"], success == .bool(true) || success == .bool(false) else { throw WalletError.invalid(L("message.the_aptos_node_returned_an_invalid_execution_status")) }; return success == .bool(true) ? WalletLocalization.legacy("receipt.confirmed") : WalletLocalization.legacy("receipt.failed")
        case .tron:
            let transaction = try await rest("wallet/gettransactionbyid", body: .object(["value": .string(hash)]))
            if transaction == .object([:]) { return WalletLocalization.legacy("receipt.pending") }
            guard transaction["txID"]?.string?.lowercased() == hash.lowercased(), case .array(let results) = transaction["ret"], results.count == 1, let outcome = results[0]["contractRet"]?.string else { throw WalletError.invalid(L("message.the_tron_node_returned_an_invalid_transaction_result")) }
            if outcome != "SUCCESS" { return WalletLocalization.legacy("receipt.failed") }
            let confirmed = try await rest("walletsolidity/gettransactioninfobyid", body: .object(["value": .string(hash)]))
            if confirmed == .object([:]) { return WalletLocalization.legacy("receipt.pending") }
            guard confirmed["id"]?.string?.lowercased() == hash.lowercased(), try integer(confirmed["blockNumber"]) > 0 else { throw WalletError.invalid(L("message.the_tron_solidity_node_returned_an_invalid_receipt")) }
            if let result = confirmed["result"], result != .string("SUCESS") { return WalletLocalization.legacy("receipt.failed") }
            guard case .array(let contracts) = transaction["raw_data"]?["contract"], contracts.count == 1, let type = contracts[0]["type"]?.string else { throw WalletError.invalid(L("message.tron_transaction_is_missing_its_contract_type")) }
            if type == "TriggerSmartContract" {
                guard let outcome = confirmed["receipt"]?["result"]?.string else { throw WalletError.invalid(L("message.tron_solidified_receipt_is_missing_the_contract_execution_result")) }
                guard outcome == "SUCCESS" else { return WalletLocalization.legacy("receipt.failed") }
                guard case .array(let outputs) = confirmed["contractResult"], outputs.count == 1, let encoded = outputs[0].string, let output = try? Data(strictHex: encoded) else { throw WalletError.invalid(L("message.tron_solidified_receipt_is_missing_valid_contract_return_data")) }
                if let data = contracts[0]["parameter"]?["value"]?["data"]?.string, data.lowercased().hasPrefix("095ea7b3"), output.count == 32, output.allSatisfy({ $0 == 0 }) { return WalletLocalization.legacy("receipt.failed") }
            } else if type != "TransferContract" { throw WalletError.invalid(L("message.confirmation_for_this_tron_contract_type_is_unsupported")) }
            return WalletLocalization.legacy("receipt.confirmed")
        default: throw WalletError.invalid(L("message.this_network_has_no_receipt_adapter_yet"))
        }
    }
}
