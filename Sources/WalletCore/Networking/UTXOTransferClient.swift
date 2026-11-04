import Foundation
import BigInt

struct SpendableUTXO: Sendable {
    let txid: String
    let index: UInt32
    let value: BigUInt
}
extension NativeTransferClient {
    public func suggestedUTXOFeeRate() async throws -> BigUInt {
        try await verifyUTXONetwork()
        let values = try JSONDecoder().decode([String: Decimal].self, from: await raw("fee-estimates"))
        guard let quote = values["6"], quote > 0 else { throw WalletError.invalid(L("message.the_node_did_not_provide_a_valid_six_block_fee")) }
        let pieces = NSDecimalNumber(decimal: quote).stringValue.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let units = pieces.first.flatMap({ BigUInt(String($0)) }), units < 1_000_000 else { throw WalletError.invalid(L("message.the_node_fee_rate_is_outside_the_supported_range")) }
        return units + (pieces.count == 2 && pieces[1].contains(where: { $0 != "0" }) ? 1 : 0)
    }
    func utxos(address: String) async throws -> [SpendableUTXO] {
        let result = try await rest("address/" + address + "/utxo")
        guard case .array(let rows) = result, rows.count <= 10_000 else { throw WalletError.invalid(L("message.invalid_or_oversized_utxo_list")) }
        return try rows.filter { $0["status"]?["confirmed"] == .bool(true) }.map { row in
            guard let id = row["txid"]?.string, (try? Data(strictHex: id).count) == 32 else { throw WalletError.invalid(L("message.invalid_utxo_transaction_id")) }
            let index = try integer(row["vout"]); let value = try integer(row["value"])
            guard index <= UInt32.max, value > 0, value.bitWidth <= 63 else { throw WalletError.invalid(L("message.invalid_utxo_amount_or_output_index")) }
            return SpendableUTXO(txid: id, index: UInt32(index), value: value)
        }
    }
    func prepareUTXO(account: WalletAccount, recipient: String, units: BigUInt) async throws -> (payload: NativeTransferPayload, fee: BigUInt, details: [String]) {
        guard units >= 1000, let profile = account.profile else { throw WalletError.invalid(L("message.transparent_transfers_require_at_least_1_000_base_units_to")) }
        let sender = chain.family == .litecoin ? try Litecoin.addressInfo(account.networkAddress).canonicalAddress : account.networkAddress
        let destination = chain.family == .litecoin ? try Litecoin.addressInfo(recipient).canonicalAddress : recipient
        let available = try await utxos(address: sender).filter { !reservedInputs.contains($0.txid.lowercased() + ":" + String($0.index)) }.sorted { $0.value > $1.value }
        let estimates = try JSONDecoder().decode([String: Decimal].self, from: await raw("fee-estimates"))
        guard let quoted = estimates["6"], quoted > 0 else { throw WalletError.invalid(L("message.the_node_did_not_return_a_fee_rate_for_the")) }
        let feeText = NSDecimalNumber(decimal: quoted).stringValue
        let pieces = feeText.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let integer = BigUInt(String(pieces[0])), integer < 1_000_000 else { throw WalletError.invalid(L("message.utxo_fee_rate_out_of_range")) }
        let rate = integer + (pieces.count == 2 && pieces[1].contains(where: { $0 != "0" }) ? 1 : 0)
        guard rate > 0 else { throw WalletError.invalid(L("message.the_utxo_fee_rate_cannot_be_zero")) }
        let inputSize: Int
        switch profile.variant { case "legacy": inputSize = 181; case "nested", "nested-compat": inputSize = 92; case "segwit": inputSize = 69; case "taproot": inputSize = 58; default: throw WalletError.invalid(L("message.this_script_type_has_no_verifiable_single_key_spending_rule")) }
        // 43 bytes bounds every supported transparent recipient/change output; each
        // input is bounded by a maximum DER signature, including uncompressed legacy.
        var selected: [SpendableUTXO] = []; var total: BigUInt = 0; var fee: BigUInt = 0
        for item in available.prefix(20) {
            selected.append(item); total += item.value; fee = rate * BigUInt(12 + selected.count * inputSize + 86)
            if total >= units + fee { break }
        }
        guard total >= units + fee, !selected.isEmpty else { throw WalletError.invalid(L("message.insufficient_confirmed_utxos_or_more_than_the_supported_20_inputs")) }
        var change = total - units - fee
        if change < 1000 { fee += change; change = 0 }
        var payload = NativeTransferPayload(); payload.from = account.networkAddress; payload.to = destination; payload.amount = String(units); payload.fee = String(fee); payload.change = String(change)
        payload.replaceable = true
        for item in selected {
            let raw = try await self.raw("tx/" + item.txid + "/hex")
            let previous = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard previous.utf8.count <= 200_000 else { throw WalletError.invalid(L("message.the_source_transaction_is_too_large_for_local_input_verification")) }
            payload.inputs.append(NativeTransferInput(txid: item.txid, index: item.index, value: String(item.value), previous: previous))
        }
        // The offline builder verifies each previous txid, amount and locking script
        // before any private key is requested. The signing path verifies all scripts.
        _ = try build(payload, profile: profile)
        return (payload, fee, [L("message.fee_rate_0_base_units_vbyte_target_6_blocks", rate), L("message.rbf_enabled_while_unconfirmed_you_can_re_authenticate_to_preview"), L("message.uses_only_confirmed_utxos_at_the_selected_address_0", selected.count), L("message.change_returns_to_the_selected_address_0_1", Ethereum.formatUnits(change, decimals: chain.decimals, precision: chain.decimals), chain.symbol), L("message.source_transaction_hashes_output_amounts_and_locking_scripts_were_verified")])
    }
}
