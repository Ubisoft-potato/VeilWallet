import Foundation
import BigInt

public struct NativeTransferClient: Sendable {
    let transport: any PrivateRequesting
    public let chain: Chain
    let isolation: String
    let reservedInputs: Set<String>
    public init(transport: any PrivateRequesting, chain: Chain, isolation: String, reservedInputs: Set<String> = []) { self.transport = transport; self.chain = chain; self.isolation = isolation; self.reservedInputs = reservedInputs }
    public func prepare(account: WalletAccount, recipient: String, amount: String, publicKey: Data? = nil, memo: String = "", gasPrice: String? = nil) async throws -> NativeTransferPlan {
        guard NativeTransferPlan.supports(account: account, chain: chain), let profile = account.profile, MultichainCrypto.validateAddress(recipient, profile: profile) else { throw WalletError.invalid(L("message.sending_is_unsupported_for_this_address_type_or_the_recipient")) }
        let units = try Ethereum.parseUnits(amount, decimals: chain.decimals)
        guard units > 0, units.bitWidth <= (chain.family == .cosmos ? 256 : 63) else { throw WalletError.invalid(L("message.the_send_amount_must_be_a_positive_integer_within_the")) }
        let balance = try await NativeBalanceClient(transport: transport, chain: chain, isolation: isolation).balance(account: account)
        guard balance >= units else { throw WalletError.invalid(L("message.insufficient_native_asset_balance")) }
        var payload = NativeTransferPayload(); payload.from = account.networkAddress; payload.to = recipient; payload.amount = String(units)
        var fee: BigUInt; var details: [String] = []
        switch chain.family {
        case .cosmos:
            guard let publicKey else { throw WalletError.invalid(L("message.cosmos_sending_requires_the_current_signing_public_key")) }
            let result = try await prepareCosmos(account: account, recipient: recipient, units: units, publicKey: publicKey, memo: memo, gasPrice: gasPrice)
            payload = result.payload; fee = result.fee; details = result.details
        case .bitcoin, .litecoin:
            let result = try await prepareUTXO(account: account, recipient: recipient, units: units)
            payload = result.payload; fee = result.fee; details = result.details
        case .solana:
            let latest = try await rpc("getLatestBlockhash", [.object(["commitment": .string("confirmed")])])
            guard let hash = latest["value"]?["blockhash"]?.string else { throw WalletError.invalid(L("message.latest_solana_blockhash_missing")) }
            payload.blockHash = hash
            let built = try build(payload, profile: profile)
            guard let unsigned = built.unsigned else { throw WalletError.invalid(L("message.could_not_build_the_solana_message")) }
            let message = try Data(strictHex: unsigned).base64EncodedString()
            let result = try await rpc("getFeeForMessage", [.string(message), .object(["commitment": .string("confirmed")])])
            fee = try integer(result["value"])
            guard let simulation = built.simulation else { throw WalletError.invalid(L("message.solana_simulation_data_missing")) }
            try await simulateSolana(simulation)
            details = [L("message.confirmation_level_confirmed_regular_network_fee_no_priority_fee"), L("message.blockhash_validity_is_rechecked_before_signing")]
        case .aptos:
            guard let publicKey, publicKey.count == 32 else { throw WalletError.invalid(L("message.aptos_transfers_require_the_current_account_s_public_key")) }
            let ledger = try await rest(""); guard ledger["chain_id"] == .number(1) else { throw WalletError.invalid(L("message.the_aptos_node_is_not_mainnet")) }
            let accountInfo = try await rest("accounts/" + account.networkAddress)
            guard accountInfo["authentication_key"]?.string?.lowercased() == account.networkAddress.lowercased() else { throw WalletError.invalid(L("message.the_aptos_authentication_key_rotated_this_screen_does_not_guess")) }
            payload.nonce = String(try integer(accountInfo["sequence_number"]))
            payload.publicKey = publicKey.hexString
            payload.gasPrice = String(try integer(await rest("estimate_gas_price")["gas_estimate"]))
            payload.maxGas = "2000000"
            let micros = try integer(ledger["ledger_timestamp"])
            payload.expiration = String(micros / 1_000_000 + 180)
            let draft = try build(payload, profile: profile)
            guard let simulated = draft.simulation else { throw WalletError.invalid(L("message.aptos_simulation_transaction_missing")) }
            let response = try await raw("transactions/simulate", body: Data(strictHex: simulated), media: .aptosBCS, query: [URLQueryItem(name: "estimate_max_gas_amount", value: "true")])
            let json = try JSONDecoder().decode(JSONValue.self, from: response)
            guard case .array(let rows) = json, rows.count == 1, rows[0]["success"] == .bool(true) else { throw WalletError.invalid(L("message.aptos_simulation_failed_signing_is_blocked")) }
            let gasUsed = try integer(rows[0]["gas_used"])
            let allowed = try integer(rows[0]["max_gas_amount"])
            let limit = (gasUsed * 120 + 99) / 100
            guard limit > 0, limit <= allowed, limit <= 2_000_000 else { throw WalletError.invalid(L("message.the_aptos_gas_budget_exceeds_node_limits")) }
            payload.maxGas = String(limit); fee = limit * (try integer(.string(payload.gasPrice)))
            details = ["Sequence：" + payload.nonce, L("message.gas_limit_6a4d17e9") + payload.maxGas + L("message.unit_price_66112a3d") + payload.gasPrice, L("message.ordinary_ed25519_accounts_only_on_chain_authentication_key_verified")]
        case .tron:
            let block = try await rest("wallet/getnowblock", body: .object([:]))
            guard let blockID = block["blockID"]?.string else { throw WalletError.invalid(L("message.latest_tron_block_identifier_missing")) }
            let bytes = try Data(strictHex: blockID); guard bytes.count == 32 else { throw WalletError.invalid(L("message.incorrect_tron_block_identifier_length")) }
            let timestamp = try integer(block["block_header"]?["raw_data"]?["timestamp"])
            let now = BigUInt(max(0, Int(Date().timeIntervalSince1970 * 1000)))
            guard timestamp <= now + 60_000, now <= timestamp + 60_000 else { throw WalletError.invalid(L("message.invalid_tron_node_block_timestamp")) }
            payload.refBytes = bytes[6..<8].hexString; payload.refHash = bytes[8..<16].hexString
            payload.timestamp = String(timestamp); payload.expiration = String(timestamp + 180_000)
            let built = try build(payload, profile: profile)
            guard let text = built.unsigned else { throw WalletError.invalid(L("message.could_not_build_the_tron_transfer")) }
            fee = try await tronFee(recipient: recipient, transactionSize: Data(strictHex: text).count + 80)
            details = [L("message.fees_budget_worst_case_bandwidth_burn_and_account_activation_actual"), L("message.the_trx_budget_is_not_an_on_chain_fee_cap")]
        default: throw WalletError.invalid(L("message.native_asset_sending_is_unsupported_for_this_protocol"))
        }
        guard balance >= units + fee else { throw WalletError.invalid(L("message.native_balance_cannot_cover_the_amount_and_fee_budget")) }
        let built = try build(payload, profile: profile)
        guard let unsigned = built.unsigned else { throw WalletError.invalid(L("message.offline_transfer_building_failed")) }
        return NativeTransferPlan(chainID: chain.id, profileID: profile.id, family: chain.family, sender: account.networkAddress, recipient: recipient, amount: units, feeBudget: fee, preparedAt: Date(), details: details, payload: payload, unsigned: unsigned)
    }
    public func revalidate(_ plan: NativeTransferPlan, account: WalletAccount) async throws {
        guard !plan.isExpired, plan.chainID == chain.id, plan.profileID == account.profileID, plan.sender == account.networkAddress, NativeTransferPlan.supports(account: account, chain: chain) else { throw WalletError.invalid(L("message.transfer_preview_expired_or_the_network_address_changed")) }
        if plan.contract != nil { try await TronContractClient(transport: transport, chain: chain, isolation: isolation).revalidate(plan); return }
        let balance = try await NativeBalanceClient(transport: transport, chain: chain, isolation: isolation).balance(account: account)
        guard balance >= plan.amount + plan.feeBudget else { throw WalletError.invalid(L("message.balance_changed_rebuild_the_transfer")) }
        switch chain.family {
        case .cosmos: try await revalidateCosmos(plan, account: account)
        case .bitcoin, .litecoin:
            let current = try await utxos(address: chain.family == .litecoin ? Litecoin.addressInfo(plan.sender).canonicalAddress : plan.sender)
            for selected in plan.payload.inputs {
                guard current.contains(where: { $0.txid == selected.txid && $0.index == selected.index && $0.value == BigUInt(selected.value) }) else { throw WalletError.invalid(L("message.selected_utxos_changed_or_were_spent_rebuild_the_transaction")) }
            }
        case .solana:
            let result = try await rpc("isBlockhashValid", [.string(plan.payload.blockHash), .object(["commitment": .string("confirmed")])])
            guard result["value"] == .bool(true) else { throw WalletError.invalid(L("message.solana_blockhash_expired_rebuild_the_transaction")) }
            guard let profile = account.profile, let simulation = try build(plan.payload, profile: profile).simulation else { throw WalletError.invalid(L("message.solana_simulation_transaction_missing")) }; try await simulateSolana(simulation)
        case .aptos:
            let info = try await rest("accounts/" + plan.sender)
            guard info["sequence_number"]?.string == plan.payload.nonce, info["authentication_key"]?.string?.lowercased() == plan.sender.lowercased() else { throw WalletError.invalid(L("message.aptos_account_sequence_or_authentication_key_changed")) }
            let ledger = try await rest("")
            guard try integer(ledger["ledger_timestamp"]) / 1_000_000 + 15 < integer(.string(plan.payload.expiration)) else { throw WalletError.invalid(L("message.the_aptos_transaction_is_about_to_expire")) }
        case .tron:
            let fee = try await tronFee(recipient: plan.recipient, transactionSize: Data(strictHex: plan.unsigned).count + 80)
            guard fee <= plan.feeBudget else { throw WalletError.invalid(L("message.tron_fees_exceed_the_preview_budget")) }
            let info = try await rest("wallet/getaccount", body: .object(["address": .string(plan.sender), "visible": .bool(true)]))
            if let owner = info["owner_permission"] {
                guard case .array(let keys) = owner["keys"], keys.count == 1, try integer(owner["threshold"]) == 1, keys[0]["address"]?.string == plan.sender, try integer(keys[0]["weight"]) >= 1 else { throw WalletError.invalid(L("message.multisignature_or_modified_owner_permission_tron_accounts_are_unsupported_by")) }
            }
        default: throw WalletError.invalid(L("message.transfer_revalidation_is_unsupported_for_this_protocol"))
        }
    }
    public func broadcast(_ signed: NativeSignedTransfer) async throws -> String {
        guard signed.family == chain.family, signed.chainID == chain.id else { throw WalletError.invalid(L("message.broadcast_network_differs_from_the_signed_transaction")) }
        switch chain.family {
        case .cosmos:
            let result = try await rest("cosmos/tx/v1beta1/txs", body: .object(["tx_bytes": .string(signed.encoded), "mode": .string("BROADCAST_MODE_SYNC")]))
            guard let response = result["tx_response"], response["txhash"]?.string?.uppercased() == signed.hash.uppercased(), try integer(response["code"]) == 0 else { throw WalletError.invalid(L("message.the_cosmos_node_did_not_confirm_acceptance_query_the_local")) }
        case .bitcoin, .litecoin:
            let result = try await raw("tx", body: Data(signed.encoded.utf8), media: .text)
            guard String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == signed.hash else { throw WalletError.invalid(L("message.the_node_returned_a_different_utxo_hash_query_the_local")) }
        case .solana:
            let result = try await rpc("sendTransaction", [.string(signed.encoded), .object(["encoding": .string("base64"), "skipPreflight": .bool(false), "preflightCommitment": .string("confirmed"), "maxRetries": .number(0)])])
            guard result.string == signed.hash else { throw WalletError.invalid(L("message.solana_returned_a_different_signature")) }
        case .aptos:
            let result = try JSONDecoder().decode(JSONValue.self, from: await raw("transactions", body: Data(strictHex: signed.encoded), media: .aptosBCS))
            guard result["hash"]?.string?.lowercased() == signed.hash.lowercased() else { throw WalletError.invalid(L("message.aptos_returned_a_different_transaction_hash")) }
        case .tron:
            let result = try await rest("wallet/broadcasthex", body: .object(["transaction": .string(signed.encoded)]))
            guard result["result"] == .bool(true), result["txid"]?.string?.lowercased() == signed.hash.lowercased() else { throw WalletError.invalid(L("message.tron_did_not_confirm_acceptance_query_the_local_hash")) }
        default: throw WalletError.invalid(L("message.broadcast_is_unsupported_for_this_protocol"))
        }
        return signed.hash
    }
    func build(_ payload: NativeTransferPayload, profile: AccountProfile) throws -> MultichainCrypto.Response {
        try MultichainCrypto.execute(.init(action: "transferBuild", profile: profile, transfer: payload))
    }
    func rpc(_ method: String, _ params: [JSONValue]) async throws -> JSONValue {
        let id = UUID().uuidString
        let result = try await rest("", body: .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .array(params)]))
        guard result["id"] == .string(id), result["jsonrpc"] == .string("2.0"), result["error"] == nil || result["error"] == .null, let value = result["result"] else { throw WalletError.rpc(L("message.the_multichain_node_rejected_the_request_or_returned_a_mismatched")) }; return value
    }
    func rest(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await raw(path, body: body.map { try JSONEncoder().encode($0) }))
    }
    func raw(_ path: String, body: Data? = nil, media: PrivateRequest.MediaType = .json, query: [URLQueryItem] = []) async throws -> Data {
        guard chain.configured, var parts = URLComponents(string: chain.rpcURL) else { throw WalletError.invalid(L("message.configure_this_network_s_https_endpoint_first")) }
        if !path.isEmpty { parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path; if !parts.path.hasPrefix("/") { parts.path = "/" + parts.path } }
        if !query.isEmpty { parts.queryItems = (parts.queryItems ?? []) + query }
        guard let url = parts.url else { throw WalletError.invalid(L("message.invalid_endpoint_address")) }
        return try await transport.execute(PrivateRequest(url: url, body: body, isolation: isolation, mediaType: media))
    }
    func integer(_ value: JSONValue?) throws -> BigUInt {
        if case .unsigned(let n) = value { return BigUInt(n) }
        if case .number(let n) = value, n >= 0 { return BigUInt(n) }
        guard let text = value?.string, !text.isEmpty, text.count <= 80, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = BigUInt(text), n.bitWidth <= 256 else { throw WalletError.invalid(L("message.the_node_returned_an_invalid_integer")) }; return n
    }
    private func simulateSolana(_ encoded: String) async throws {
        let result = try await rpc("simulateTransaction", [.string(encoded), .object(["encoding": .string("base64"), "sigVerify": .bool(false), "commitment": .string("confirmed"), "replaceRecentBlockhash": .bool(false)])])
        guard let error = result["value"]?["err"], error == .null else { throw WalletError.invalid(L("message.solana_simulation_failed_signing_is_blocked")) }
    }
    private func tronFee(recipient: String, transactionSize: Int) async throws -> BigUInt {
        let parameters = try await rest("wallet/getchainparameters", body: .object([:]))
        guard case .array(let rows) = parameters["chainParameter"] else { throw WalletError.invalid(L("message.tron_on_chain_fee_parameters_missing")) }
        func parameter(_ key: String) throws -> BigUInt {
            guard let row = rows.first(where: { $0["key"] == .string(key) }) else { throw WalletError.invalid(L("message.the_tron_node_is_missing_required_fee_parameters")) }; return try integer(row["value"])
        }
        var amount = try parameter("getTransactionFee") * BigUInt(transactionSize)
        let account = try await rest("wallet/getaccount", body: .object(["address": .string(recipient), "visible": .bool(true)]))
        if account == .object([:]) { amount += try parameter("getCreateNewAccountFeeInSystemContract") + parameter("getCreateAccountFee") }
        else { guard account["address"] != nil else { throw WalletError.invalid(L("message.tron_returned_an_invalid_recipient_account_status")) } }
        return (amount * 120 + 99) / 100
    }
}
