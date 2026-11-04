import Foundation
import BigInt

public struct NativeBalanceClient: Sendable {
    let transport: any PrivateRequesting
    public let chain: Chain
    let isolation: String
    public init(transport: any PrivateRequesting, chain: Chain, isolation: String) { self.transport = transport; self.chain = chain; self.isolation = isolation }
    public func balance(account: WalletAccount) async throws -> BigUInt {
        guard let profile = account.profile, chain.profileKeys.contains(profile.id), account.isBound,
              MultichainCrypto.validateAddress(account.networkAddress, profile: profile) else { throw WalletError.invalid(L("message.the_account_is_not_linked_to_this_network_or_its")) }
        guard account.supportsPublicBalanceQuery else { throw WalletError.invalid(L("message.mweb_balances_require_local_scanning_this_version_does_not_give")) }
        let address = chain.family == .litecoin ? try Litecoin.addressInfo(account.networkAddress).canonicalAddress : account.networkAddress
        switch chain.family {
        case .solana:
            let genesis = try await rpc("getGenesisHash", [])
            guard genesis.string == "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" else { throw WalletError.invalid(L("message.the_solana_node_is_not_mainnet")) }
            let value = try await rpc("getBalance", [.string(address), .object(["commitment": .string("confirmed")])])
            return try integer(value["value"])
        case .bitcoin, .litecoin:
            let genesis = try await raw(path: "block-height/0")
            let expected = chain.family == .litecoin ? Litecoin.mainnetGenesis : "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
            guard String(decoding: genesis, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected else { throw WalletError.invalid(L("message.utxo_node_genesis_does_not_match_the_selected_network")) }
            let value = try await rest(path: "address/" + address)
            let funded = try integer(value["chain_stats"]?["funded_txo_sum"]) + integer(value["mempool_stats"]?["funded_txo_sum"])
            let spent = try integer(value["chain_stats"]?["spent_txo_sum"]) + integer(value["mempool_stats"]?["spent_txo_sum"])
            guard funded >= spent else { throw WalletError.invalid(L("message.the_bitcoin_node_returned_inconsistent_balances")) }; return funded - spent
        case .tron:
            let genesis = try await rest(path: "wallet/getblockbynum", body: .object(["num": .number(0)]))
            guard genesis["blockID"] == .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc") else { throw WalletError.invalid(L("message.tron_node_genesis_does_not_match_mainnet")) }
            let value = try await rest(path: "wallet/getaccount", body: .object(["address": .string(address), "visible": .bool(true)]))
            if value == .object([:]) { return 0 }
            guard value["Error"] == nil, value["error"] == nil, value["address"] != nil || value["balance"] != nil else { throw WalletError.rpc(L("message.the_tron_node_returned_invalid_account_data")) }
            return try integer(value["balance"] ?? .number(0))
        case .sui:
            let query = "query WalletBalance($address: SuiAddress!) { chainIdentifier address(address: $address) { balance(coinType: \"0x2::sui::SUI\") { totalBalance } } }"
            let result = try await rest(path: "", body: .object(["query": .string(query), "variables": .object(["address": .string(address)])]))
            guard result["errors"] == nil || result["errors"] == .array([]) else { throw WalletError.rpc(L("message.the_sui_graphql_node_rejected_the_request")) }
            let identifier = result["data"]?["chainIdentifier"]?.string
            guard identifier == "35834a8a" || identifier == "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S" else { throw WalletError.invalid(L("message.the_sui_node_is_not_mainnet")) }
            return try integer(result["data"]?["address"]?["balance"]?["totalBalance"])
        case .aptos:
            let ledger = try await rest(path: "")
            guard ledger["chain_id"] == .number(1) else { throw WalletError.invalid(L("message.the_aptos_node_is_not_mainnet")) }
            let result = try await rest(path: "view", body: .object(["function": .string("0x1::coin::balance"), "type_arguments": .array([.string("0x1::aptos_coin::AptosCoin")]), "arguments": .array([.string(address)])]))
            guard case .array(let items) = result, let value = items.first else { throw WalletError.invalid(L("message.the_aptos_node_returned_an_invalid_balance")) }; return try integer(value)
        case .ton:
            let result = try await rest(path: "getAddressBalance", body: .object(["address": .string(address)]))
            guard result["ok"] == .bool(true), result["error"] == nil else { throw WalletError.rpc(L("message.ton_center_rejected_the_balance_query")) }
            return try integer(result["result"])
        case .cosmos:
            guard let denomination = chain.denomination else { throw WalletError.invalid(L("message.cosmos_asset_denomination_missing")) }
            let result = try await rest(path: "cosmos/bank/v1beta1/balances/\(address)/by_denom", query: [URLQueryItem(name: "denom", value: denomination)])
            guard result["balance"]?["denom"]?.string == denomination else { throw WalletError.invalid(L("message.the_cosmos_node_returned_a_different_asset_denomination")) }
            return try integer(result["balance"]?["amount"])
        case .near:
            let result = try await rpc("query", objectParams: ["request_type": .string("view_account"), "finality": .string("final"), "account_id": .string(address)])
            return try integer(result["amount"])
        case .stacks:
            let result = try await rest(path: "extended/v1/address/\(address)/stx")
            let amount = try integer(result["balance"])
            let locked = try integer(result["locked"] ?? .string("0"))
            guard amount >= locked else { throw WalletError.invalid(L("message.stacks_returned_an_invalid_locked_balance")) }; return amount - locked
        case .polkadot:
            let version = try await rpc("state_getRuntimeVersion", [])
            guard version["specName"]?.string == "polkadot" else { throw WalletError.invalid(L("message.the_substrate_node_is_not_polkadot")) }
            guard let key = try MultichainCrypto.execute(.init(action: "storageKey", profile: profile, address: address)).storageKey else { throw WalletError.invalid(L("message.could_not_generate_the_system_account_storage_key")) }
            let result = try await rpc("state_getStorage", [.string(key)])
            if result == .null { return 0 }
            guard let hex = result.string else { throw WalletError.invalid(L("message.polkadot_returned_invalid_storage_data")) }
            let data = try Data(strictHex: hex)
            guard data.count == 80 else { throw WalletError.invalid(L("message.this_polkadot_accountinfo_encoding_version_is_unsupported")) }
            return BigUInt(Data(data[16..<32].reversed()))
        case .cardano:
            let result = try await rest(path: "address_info", body: .object(["_addresses": .array([.string(address)])]))
            guard case .array(let rows) = result else { throw WalletError.invalid(L("message.the_cardano_indexer_returned_invalid_data")) }
            if rows.isEmpty { return 0 }; return try integer(rows[0]["balance"])
        case .eos:
            let symbol = chain.symbol == "WAXP" ? "WAX" : "EOS"
            let result = try await rest(path: "v1/chain/get_currency_balance", body: .object(["code": .string("eosio.token"), "account": .string(address), "symbol": .string(symbol)]))
            guard case .array(let rows) = result else { throw WalletError.invalid(L("message.the_eos_node_returned_invalid_asset_data")) }
            if rows.isEmpty { return 0 }
            guard let text = rows[0].string, text.hasSuffix(" " + symbol) else { throw WalletError.invalid(L("message.the_eos_node_returned_the_wrong_asset")) }
            return try Ethereum.parseUnits(String(text.split(separator: " ")[0]), decimals: chain.decimals)
        case .starknet:
            guard try await rpc("starknet_chainId", []).string == "0x534e5f4d41494e" else { throw WalletError.invalid(L("message.the_starknet_node_is_not_mainnet")) }
            let selector = BigUInt(Data("balanceOf".utf8).keccak256) & ((BigUInt(1) << 250) - 1)
            let call: JSONValue = .object(["contract_address": .string("0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"), "entry_point_selector": .string(Ethereum.quantity(selector)), "calldata": .array([.string(address)])])
            let result = try await rpc("starknet_call", [call, .string("latest")])
            guard case .array(let parts) = result, parts.count == 2, let low = parts[0].string, let high = parts[1].string else { throw WalletError.invalid(L("message.starknet_returned_an_invalid_uint256")) }
            let lower = try Ethereum.decodeQuantity(low); let upper = try Ethereum.decodeQuantity(high)
            guard lower.bitWidth <= 128, upper.bitWidth <= 128 else { throw WalletError.invalid(L("message.starknet_returned_an_out_of_range_uint256")) }
            return lower + (upper << 128)
        default: throw WalletError.invalid(L("message.this_network_has_no_balance_adapter_yet"))
        }
    }
    private func rpc(_ method: String, _ params: [JSONValue]) async throws -> JSONValue { try await jsonRPC(method, params: .array(params)) }
    private func rpc(_ method: String, objectParams: [String: JSONValue]) async throws -> JSONValue { try await jsonRPC(method, params: .object(objectParams)) }
    private func jsonRPC(_ method: String, params: JSONValue) async throws -> JSONValue {
        let id = UUID().uuidString
        let response = try await rest(path: "", body: .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params]))
        guard response["id"] == .string(id), response["jsonrpc"] == .string("2.0"), response["error"] == nil || response["error"] == .null, let result = response["result"] else { throw WalletError.rpc(L("message.the_multichain_node_rejected_the_request_or_returned_a_mismatched")) }
        return result
    }
    private func rest(path: String, body: JSONValue? = nil, query: [URLQueryItem] = []) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await raw(path: path, body: body, query: query))
    }
    private func raw(path: String, body: JSONValue? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard chain.configured, var components = URLComponents(string: chain.rpcURL) else { throw WalletError.invalid(L("message.configure_this_network_s_https_endpoint_in_settings_first")) }
        if !path.isEmpty { components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path; if !components.path.hasPrefix("/") { components.path = "/" + components.path } }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let url = components.url else { throw WalletError.invalid(L("message.invalid_multichain_endpoint_address")) }
        return try await transport.execute(PrivateRequest(url: url, body: body.map { try JSONEncoder().encode($0) }, isolation: isolation))
    }
    private func integer(_ value: JSONValue?) throws -> BigUInt {
        if case .unsigned(let n) = value { return BigUInt(n) }
        if case .number(let n) = value, n >= 0 { return BigUInt(n) }
        if let text = value?.string, text.count <= 80, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = BigUInt(text) { return n }
        throw WalletError.invalid(L("message.the_node_returned_an_invalid_integer_balance"))
    }
}
