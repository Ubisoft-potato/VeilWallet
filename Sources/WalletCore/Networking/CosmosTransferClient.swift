import Foundation
import BigInt

public enum CosmosTransferConfiguration {
    // cosmos/chain-registry chain.json, recorded in Documentation/COSMOS_SOURCES.json.
    // Retired networks and Terra Classic's separate tax accounting remain disabled.
    public static let chainIdentifiers: [String: String] = [
        "cosmos": "cosmoshub-4", "osmosis": "osmosis-1", "celestia": "celestia", "injective": "injective-1",
        "sei.cosmos": "pacific-1", "juno": "juno-1", "akash": "akashnet-2", "secret": "secret-4", "kujira": "kaiyo-1",
        "stride": "stride-1", "neutron": "neutron-1", "dydx": "dydx-mainnet-1", "noble": "noble-1", "persistence": "core-1",
        "axelar": "axelar-dojo-1", "band": "laozi-mainnet", "iris": "irishub-1", "kava.cosmos": "kava_2222-10",
        "terra": "phoenix-1", "chihuahua": "chihuahua-1", "sentinel": "sentinelhub-2"
    ]
}

extension NativeTransferClient {
    func prepareCosmos(account: WalletAccount, recipient: String, units: BigUInt, publicKey: Data, memo: String, gasPrice: String?) async throws -> (payload: NativeTransferPayload, fee: BigUInt, details: [String]) {
        guard let profile = account.profile, let identifier = CosmosTransferConfiguration.chainIdentifiers[profile.id], let denom = chain.denomination, publicKey.count == 33, memo.utf8.count <= 256 else { throw WalletError.invalid(L("message.this_cosmos_chain_signing_public_key_or_memo_is_unsupported")) }
        let height = try await cosmosHead(identifier: identifier)
        let auth = try await cosmosAccount(account.networkAddress, publicKey: publicKey, eth: profile.variant == "eth")
        let price: String
        if let gasPrice, !gasPrice.isEmpty { price = gasPrice }
        else {
            let config = try await rest("cosmos/base/node/v1beta1/config")
            guard let configured = config["minimum_gas_price"]?.string,
                  let entry = configured.split(separator: ",").map(String.init).first(where: { $0.hasSuffix(denom) }) else { throw WalletError.invalid(L("message.the_node_did_not_provide_a_gas_price_in_this")) }
            price = String(entry.dropLast(denom.count))
        }
        // Fixed-point arithmetic only. Price is in the denomination's smallest unit per gas.
        let scaledPrice = try Ethereum.parseUnits(price, decimals: 18)
        guard scaledPrice.bitWidth <= 128 else { throw WalletError.invalid(L("message.cosmos_gas_price_is_out_of_range")) }
        var payload = NativeTransferPayload()
        payload.from = account.networkAddress; payload.to = recipient; payload.amount = String(units)
        payload.chainIdentifier = identifier; payload.denomination = denom; payload.accountNumber = auth.number; payload.nonce = auth.sequence
        payload.publicKey = publicKey.hexString; payload.memo = memo; payload.expiration = String(height + 100)
        payload.maxGas = "5000000"; payload.fee = "0"
        let draft = try build(payload, profile: profile)
        guard let simulation = draft.simulation else { throw WalletError.invalid(L("message.could_not_build_the_cosmos_simulation_transaction")) }
        let result = try await rest("cosmos/tx/v1beta1/simulate", body: .object(["tx_bytes": .string(simulation)]))
        let gas = (try integer(result["gas_info"]?["gas_used"]) * 130 + 99) / 100
        guard gas > 0, gas <= 5_000_000 else { throw WalletError.invalid(L("message.cosmos_simulated_gas_exceeds_the_budget_limit")) }
        let scale = BigUInt(10).power(18)
        let fee = (gas * scaledPrice + scale - 1) / scale
        payload.maxGas = String(gas); payload.fee = String(fee)
        // Re-simulate the final fee/auth bytes; zero signatures are used only for simulation.
        guard let final = try build(payload, profile: profile).simulation else { throw WalletError.invalid(L("message.could_not_build_the_final_cosmos_transaction")) }
        let check = try await rest("cosmos/tx/v1beta1/simulate", body: .object(["tx_bytes": .string(final)]))
        guard try integer(check["gas_info"]?["gas_used"]) <= gas else { throw WalletError.invalid(L("message.final_cosmos_gas_exceeds_the_budget")) }
        return (payload, fee, [L("message.chain_id") + identifier, "Account / Sequence：" + auth.number + " / " + auth.sequence, L("message.gas_limit_6a4d17e9") + payload.maxGas + L("message.unit_price_66112a3d") + price + " " + denom + "/Gas", L("message.bank_msgsend_only_excludes_ibc_staking_contracts_and_chain_specific"), "Memo：" + (memo.isEmpty ? L("message.empty_check_whether_the_exchange_requires_a_memo_before_depositing") : memo)])
    }
    func revalidateCosmos(_ plan: NativeTransferPlan, account: WalletAccount) async throws {
        let payload = plan.payload
        guard CosmosTransferConfiguration.chainIdentifiers[account.profileID] == payload.chainIdentifier, chain.denomination == payload.denomination else { throw WalletError.invalid(L("message.cosmos_chain_identity_does_not_match_the_approved_transaction")) }
        let height = try await cosmosHead(identifier: payload.chainIdentifier)
        guard try height + 3 < integer(.string(payload.expiration)) else { throw WalletError.invalid(L("message.cosmos_transaction_is_nearing_its_timeout_height")) }
        let auth = try await cosmosAccount(plan.sender, publicKey: Data(strictHex: payload.publicKey), eth: account.profile?.variant == "eth")
        guard auth.number == payload.accountNumber, auth.sequence == payload.nonce else { throw WalletError.invalid(L("message.cosmos_account_sequence_changed_rebuild_the_transaction")) }
        guard let profile = account.profile, let simulation = try build(payload, profile: profile).simulation else { throw WalletError.invalid(L("message.cosmos_simulation_transaction_missing")) }
        let result = try await rest("cosmos/tx/v1beta1/simulate", body: .object(["tx_bytes": .string(simulation)]))
        guard try integer(result["gas_info"]?["gas_used"]) <= integer(.string(payload.maxGas)) else { throw WalletError.invalid(L("message.cosmos_simulation_exceeds_the_approved_gas_limit")) }
    }
    func cosmosHead(identifier: String) async throws -> BigUInt {
        let info = try await rest("cosmos/base/tendermint/v1beta1/node_info")
        guard info["default_node_info"]?["network"] == .string(identifier) else { throw WalletError.invalid(L("message.cosmos_node_chain_id_does_not_match_the_current_network")) }
        let latest = try await rest("cosmos/base/tendermint/v1beta1/blocks/latest")
        guard let header = latest["block"]?["header"] ?? latest["sdk_block"]?["header"], header["chain_id"] == .string(identifier), let time = header["time"]?.string,
              let date = Self.cosmosDate(time), abs(date.timeIntervalSinceNow) <= 300 else { throw WalletError.invalid(L("message.cosmos_block_header_is_missing_the_chain_id_is_wrong")) }
        let height = try integer(header["height"])
        guard height > 0, height.bitWidth <= 63 else { throw WalletError.invalid(L("message.invalid_cosmos_height")) }; return height
    }
    private static func cosmosDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
    private func cosmosAccount(_ address: String, publicKey: Data, eth: Bool) async throws -> (number: String, sequence: String) {
        var value = try await rest("cosmos/auth/v1beta1/accounts/" + address)["account"]
        for _ in 0..<4 {
            if value?["account_number"] != nil { break }
            value = value?["base_account"] ?? value?["base_vesting_account"]
        }
        guard let value, value["address"] == .string(address), value["@type"] == nil || value["@type"] == .string("/cosmos.auth.v1beta1.BaseAccount") || value["@type"] == .string("/ethermint.types.v1.EthAccount") else { throw WalletError.invalid(L("message.the_cosmos_account_is_not_a_supported_ordinary_single_signature")) }
        if let pub = value["pub_key"], pub != .null {
            let expected = eth ? "/injective.crypto.v1beta1.ethsecp256k1.PubKey" : "/cosmos.crypto.secp256k1.PubKey"
            guard pub["@type"] == .string(expected), let encoded = pub["key"]?.string, Data(base64Encoded: encoded) == publicKey else { throw WalletError.invalid(L("message.cosmos_on_chain_public_key_type_or_authority_changed")) }
        }
        let number = try integer(value["account_number"]), sequence = try integer(value["sequence"])
        guard number.bitWidth <= 64, sequence.bitWidth <= 64 else { throw WalletError.invalid(L("message.cosmos_account_sequence_is_out_of_range")) }
        return (String(number), String(sequence))
    }
}
