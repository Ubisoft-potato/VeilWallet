import Foundation
import BigInt

public struct TronInvocation: Codable, Equatable, Sendable {
    public let contract: String
    public let signature: String
    public let arguments: [String]
    public let callValue: BigUInt
    public let data: Data
    public init(contract: String, signature: String, arguments: [String], callValue: BigUInt = 0) throws {
        guard TronAddress.validate(contract), callValue.bitWidth <= 63 else { throw WalletError.invalid(L("message.invalid_tron_contract_or_attached_trx")) }
        self.contract = contract; self.signature = signature; self.arguments = arguments; self.callValue = callValue
        data = try ContractABI.encode(signature: signature, arguments: arguments)
    }
}

public struct TronContractClient: Sendable {
    let native: NativeTransferClient
    public var chain: Chain { native.chain }
    public init(transport: any PrivateRequesting, chain: Chain, isolation: String) { native = NativeTransferClient(transport: transport, chain: chain, isolation: isolation) }
    public func verifyChain() async throws {
        guard chain.family == .tron else { throw WalletError.invalid(L("message.the_selected_network_is_not_tron")) }
        let genesis = try await native.rest("wallet/getblockbynum", body: .object(["num": .number(0)]))
        guard genesis["blockID"] == .string(try TronNetwork.genesis(for: chain)) else { throw WalletError.invalid(L("tron.network_mismatch")) }
    }
    func verifyCode(_ address: String) async throws {
        guard TronAddress.validate(address) else { throw WalletError.invalid(L("message.invalid_tron_contract_address")) }
        let body: JSONValue = .object(["value": .string(address), "visible": .bool(true)])
        let result = try await native.rest("wallet/getcontract", body: body)
        guard result["Error"] == nil, result["error"] == nil else { throw WalletError.invalid(L("message.the_tron_node_rejected_the_contract_metadata_request")) }
        if let code = result["bytecode"]?.string, let bytes = try? Data(strictHex: code), !bytes.isEmpty { return }
        // CREATE / CREATE2 contracts may omit deployment metadata. The native
        // getcontractinfo endpoint supplies the actual deployed runtime code.
        let info = try await native.rest("wallet/getcontractinfo", body: body)
        guard info["Error"] == nil, info["error"] == nil, let code = info["runtimecode"]?.string,
              let bytes = try? Data(strictHex: code), !bytes.isEmpty else { throw WalletError.invalid(L("message.no_verifiable_runtime_code_at_the_tron_destination")) }
        if let reported = info["smart_contract"]?["contract_address"]?.string { guard reported == address else { throw WalletError.invalid(L("message.the_contract_address_in_the_tron_runtime_code_does_not")) } }
    }
    public func read(_ call: TronInvocation, sender: String? = nil) async throws -> Data {
        try await verifyChain(); try await verifyCode(call.contract)
        return try await simulate(call, sender: sender ?? call.contract).output
    }
    func simulate(_ call: TronInvocation, sender: String) async throws -> (output: Data, energy: BigUInt) {
        guard TronAddress.validate(sender) else { throw WalletError.invalid(L("message.invalid_tron_caller_account")) }
        let result = try await native.rest("wallet/triggerconstantcontract", body: .object(["owner_address": .string(sender), "contract_address": .string(call.contract), "data": .string(call.data.hexString), "call_value": .unsigned(UInt64(call.callValue)), "visible": .bool(true)]))
        guard result["result"]?["result"] == .bool(true), case .array(let values) = result["constant_result"] else { throw WalletError.invalid(L("message.the_tron_contract_call_simulation_failed_signing_was_blocked")) }
        let encoded: String
        if values.count == 1, let value = values[0].string { encoded = value }
        else if values.isEmpty, ["execute(bytes,bytes[],uint256)", "approve(address,address,uint160,uint48)", BridgeClient.oftBridgeSignature].contains(call.signature) { encoded = "" }
        else { throw WalletError.invalid(L("message.the_tron_contract_result_does_not_match_the_supported_interface")) }
        // Constant-call responses may serialize proto3's default SUCESS/DEFAULT as [{}].
        // Explicit failures must still win over the top-level API success flag.
        if let outcomes = result["transaction"]?["ret"] {
            guard case .array(let rows) = outcomes, rows.count == 1, case .object = rows[0],
                  rows[0]["ret"] == nil || rows[0]["ret"] == .string("SUCESS"),
                  rows[0]["contractRet"] == nil || rows[0]["contractRet"] == .string("DEFAULT") || rows[0]["contractRet"] == .string("SUCCESS") else { throw WalletError.invalid(L("message.tron_simulation_failed")) }
        }
        let output = try Data(strictHex: encoded)
        if call.signature == "approve(address,uint256)", output.count == 32, BigUInt(output) == 0 { throw WalletError.invalid(L("message.trc20_approval_rejected")) }
        return (output, try native.integer(result["energy_used"]))
    }
    public func balance(address: String, token: Token) async throws -> BigUInt {
        guard token.chainID == chain.id else { throw WalletError.invalid(L("message.trc20_network_mismatch")) }
        return try ContractABI.uint(await read(TronInvocation(contract: token.contract, signature: "balanceOf(address)", arguments: [TronAddress.evm(address)])))
    }
    public func prepare(sender: String, invocation: TronInvocation, swap: TronDexQuote? = nil, bridge: BridgeQuote? = nil) async throws -> NativeTransferPlan {
        try await verifyChain(); try await verifyCode(invocation.contract); try await verifyOwner(sender)
        let simulation = try await simulate(invocation, sender: sender)
        let params = try await parameters()
        let limit = (simulation.energy * params.energyPrice * 150 + 99) / 100
        guard simulation.energy > 0, limit > 0, limit <= params.maxLimit, limit <= 15_000_000_000 else { throw WalletError.invalid(L("message.the_tron_energy_fee_limit_exceeds_the_node_s_permitted")) }
        let block = try await head()
        var payload = NativeTransferPayload(); payload.from = sender; payload.to = invocation.contract; payload.amount = String(invocation.callValue)
        payload.refBytes = block.refBytes; payload.refHash = block.refHash; payload.timestamp = String(block.timestamp); payload.expiration = String(block.timestamp + 180_000)
        payload.contractData = invocation.data.hexString; payload.feeLimit = String(limit)
        let profile = AccountProfile.find("tron")!
        guard let unsigned = try native.build(payload, profile: profile).unsigned else { throw WalletError.invalid(L("message.failed_to_build_the_offline_tron_contract_transaction")) }
        let bandwidth = BigUInt(try Data(strictHex: unsigned).count + 160) * params.bandwidthPrice * 120 / 100
        let budget = limit + bandwidth
        try await checkBalance(sender, required: invocation.callValue + budget)
        let details = [L("message.contract_7dd8b6f7") + invocation.contract, L("message.function_31a5b16a") + invocation.signature, L("message.energy_simulation") + String(simulation.energy) + "；fee_limit：" + Ethereum.formatUnits(limit, decimals: 6, precision: 6) + " TRX", L("message.the_fee_budget_includes_a_50_energy_buffer_and_worst"), L("message.uses_tapos_and_a_180_second_on_chain_lifetime_simulation")]
        return NativeTransferPlan(chainID: chain.id, profileID: profile.id, family: .tron, sender: sender, recipient: invocation.contract, amount: invocation.callValue, feeBudget: budget, preparedAt: Date(), details: details, payload: payload, unsigned: unsigned, contract: invocation, swap: swap, bridge: bridge)
    }
    func revalidate(_ plan: NativeTransferPlan) async throws {
        guard !plan.isExpired, plan.chainID == chain.id, let call = plan.contract, plan.payload.contractData == call.data.hexString, plan.payload.to == call.contract, plan.payload.amount == String(call.callValue), plan.amount == call.callValue else { throw WalletError.invalid(L("message.the_tron_contract_preview_does_not_match_the_signing_data")) }
        try await verifyChain(); try await verifyCode(call.contract); try await verifyOwner(plan.sender)
        if let quote = plan.swap { try await TronDexClient(client: self).revalidate(quote, sender: plan.sender) }
        if let quote = plan.bridge {
            guard try BridgeClient.tronInvocation(quote) == call else { throw WalletError.invalid(L("message.the_bridge_call_does_not_match_the_approved_preview")) }
            try await BridgeClient.revalidate(quote, sender: plan.sender, endpoint: .tron(self))
        }
        let block = try await head()
        guard try block.timestamp + 15_000 < native.integer(.string(plan.payload.expiration)) else { throw WalletError.invalid(L("message.the_tron_contract_transaction_is_about_to_expire")) }
        let simulation = try await simulate(call, sender: plan.sender), params = try await parameters()
        let limit = try native.integer(plan.payload.feeLimit.map(JSONValue.string))
        guard simulation.energy > 0, simulation.energy * params.energyPrice <= limit, limit <= params.maxLimit else { throw WalletError.invalid(L("message.simulated_tron_energy_exceeds_the_approved_fee_limit")) }
        let bandwidth = BigUInt(try Data(strictHex: plan.unsigned).count + 160) * params.bandwidthPrice * 120 / 100
        guard limit + bandwidth <= plan.feeBudget else { throw WalletError.invalid(L("message.tron_bandwidth_fees_exceed_the_preview_budget")) }
        try await checkBalance(plan.sender, required: plan.amount + plan.feeBudget)
    }
    private func checkBalance(_ sender: String, required: BigUInt) async throws {
        let account = WalletAccount(profileID: "tron", address: sender)
        guard try await NativeBalanceClient(transport: native.transport, chain: chain, isolation: native.isolation).balance(account: account) >= required else { throw WalletError.invalid(L("message.insufficient_trx_for_the_attached_amount_and_fee_budget")) }
    }
    private func verifyOwner(_ sender: String) async throws {
        let info = try await native.rest("wallet/getaccount", body: .object(["address": .string(sender), "visible": .bool(true)]))
        guard info["address"] == .string(sender) else { throw WalletError.invalid(L("message.the_tron_signing_account_is_inactive_or_does_not_match")) }
        if let owner = info["owner_permission"] {
            guard case .array(let keys) = owner["keys"], keys.count == 1, try native.integer(owner["threshold"]) == 1, keys[0]["address"] == .string(sender), try native.integer(keys[0]["weight"]) >= 1 else { throw WalletError.invalid(L("message.tron_multisig_or_owner_permissions_changed")) }
        }
    }
    private func parameters() async throws -> (energyPrice: BigUInt, bandwidthPrice: BigUInt, maxLimit: BigUInt) {
        let result = try await native.rest("wallet/getchainparameters", body: .object([:]))
        guard case .array(let rows) = result["chainParameter"] else { throw WalletError.invalid(L("message.missing_tron_fee_parameters")) }
        func value(_ key: String) throws -> BigUInt { guard let row = rows.first(where: { $0["key"] == .string(key) }) else { throw WalletError.invalid(L("message.the_tron_node_did_not_return_required_fee_parameters")) }; return try native.integer(row["value"]) }
        let energy = try value("getEnergyFee"), bandwidth = try value("getTransactionFee"), limit = try value("getMaxFeeLimit")
        guard energy > 0, bandwidth > 0, limit > 0 else { throw WalletError.invalid(L("message.invalid_tron_fee_parameters")) }; return (energy, bandwidth, limit)
    }
    private func head() async throws -> (refBytes: String, refHash: String, timestamp: BigUInt) {
        let block = try await native.rest("wallet/getnowblock", body: .object([:]))
        guard let hash = block["blockID"]?.string else { throw WalletError.invalid(L("message.missing_tron_block_identifier")) }
        let bytes = try Data(strictHex: hash); guard bytes.count == 32 else { throw WalletError.invalid(L("message.invalid_tron_block_identifier")) }
        let timestamp = try native.integer(block["block_header"]?["raw_data"]?["timestamp"]), now = BigUInt(max(0, Int(Date().timeIntervalSince1970 * 1000)))
        guard timestamp <= now + 60_000, now <= timestamp + 60_000 else { throw WalletError.invalid(L("message.the_tron_node_is_not_synchronized")) }
        return (bytes[6..<8].hexString, bytes[8..<16].hexString, timestamp)
    }
}
