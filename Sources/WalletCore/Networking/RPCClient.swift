import Foundation
import BigInt

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Int), unsigned(UInt64), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int.self) { self = .number(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public subscript(_ key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
}
public struct TransactionPreview: Codable, Sendable {
    public let transaction: EVMTransaction
    public let sender: String
    public let recipient: String
    public let amount: String
    public let symbol: String
    public let preparedAt: Date
    public let token: Token?
    public let additionalFees: EVMAdditionalFees
    public let purpose: EVMTransactionPurpose
    public let replacement: EVMReplacementReference?
    public init(transaction: EVMTransaction, sender: String, recipient: String, amount: String, symbol: String, preparedAt: Date, token: Token?, additionalFees: EVMAdditionalFees, purpose: EVMTransactionPurpose, replacement: EVMReplacementReference? = nil) {
        self.transaction = transaction; self.sender = sender; self.recipient = recipient; self.amount = amount; self.symbol = symbol; self.preparedAt = preparedAt; self.token = token; self.additionalFees = additionalFees; self.purpose = purpose; self.replacement = replacement
    }
    public var totalFeeBudget: BigUInt { transaction.maximumFee + additionalFees.budget }
    public var isExpired: Bool { Date().timeIntervalSince(preparedAt) > 90 }
}
public struct RPCClient: Sendable {
    private let transport: any PrivateRequesting
    public let chain: Chain
    private let isolation: String
    let noncePolicy: EVMNoncePolicy?
    public init(transport: any PrivateRequesting, chain: Chain, isolation: String, noncePolicy: EVMNoncePolicy? = nil) {
        self.transport = transport; self.chain = chain; self.isolation = isolation; self.noncePolicy = noncePolicy
    }
    public func call(_ method: String, params: [JSONValue]) async throws -> JSONValue {
        let allowed = ["eth_chainId", "eth_getCode", "eth_getBalance", "eth_getTransactionCount", "eth_gasPrice", "eth_estimateGas", "eth_maxPriorityFeePerGas", "eth_getBlockByNumber", "eth_getLogs", "eth_call", "eth_sendRawTransaction", "eth_getTransactionReceipt", "eth_getTransactionByHash"]
        guard allowed.contains(method), let url = URL(string: chain.rpcURL) else { throw WalletError.invalid(L("message.rpc_method_or_endpoint_is_not_allowed")) }
        let id = UUID().uuidString
        let body = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .array(params)])
        let request = try PrivateRequest(url: url, body: JSONEncoder().encode(body), isolation: isolation)
        let response = try JSONDecoder().decode(JSONValue.self, from: await transport.execute(request))
        guard response["id"] == .string(id), response["jsonrpc"] == .string("2.0") else { throw WalletError.invalid(L("message.rpc_response_does_not_match")) }
        if let error = response["error"], error != .null {
            if case .number(let code) = error["code"] { throw WalletError.rpcRejected(code) }
            throw WalletError.rpc(L("message.request_rejected_check_the_balance_gas_or_node_status"))
        }
        guard let result = response["result"] else { throw WalletError.invalid(L("message.the_node_response_is_missing_result")) }
        return result
    }
    public func verifyChain() async throws {
        let result = try await quantity("eth_chainId", [])
        guard result == BigUInt(chain.id) else { throw WalletError.invalid(L("message.node_chain_id_differs_from_the_selected_network_operation_blocked")) }
        if let expected = EVMNetworkSupport.expectedGenesisHashes[chain.id] {
            let genesis = try await call("eth_getBlockByNumber", params: [.string("0x0"), .bool(false)])
            guard genesis["hash"]?.string?.lowercased() == expected else { throw WalletError.invalid(L("message.node_genesis_differs_from_the_selected_evm_network_operation_blocked")) }
        }
    }
    public func balance(address: String, token: Token? = nil) async throws -> BigUInt {
        guard Ethereum.validateAddress(address) else { throw WalletError.invalid(L("message.invalid_address")) }
        if let token {
            guard token.chainID == chain.id else { throw WalletError.invalid(L("message.token_network_does_not_match")) }
            let data = "0x70a08231" + String(repeating: "0", count: 24) + String(address.dropFirst(2))
            return try await quantity("eth_call", [.object(["to": .string(token.contract), "data": .string(data)]), .string("latest")])
        }
        return try await quantity("eth_getBalance", [.string(address), .string("latest")])
    }
    public func feeQuote() async throws -> EVMFeeQuote {
        guard chain.isEVM else { throw WalletError.invalid(L("message.the_current_network_is_not_evm")) }
        if EVMNetworkSupport.legacyFeeChainIDs.contains(chain.id) { return try await legacyFeeQuote() }
        let block = try await call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        guard case .object = block else { throw WalletError.invalid(L("message.the_node_did_not_return_the_latest_block")) }
        if let base = block["baseFeePerGas"], base != .null {
            guard let text = base.string else { throw WalletError.invalid(L("message.the_node_returned_an_invalid_basefee")) }
            let amount = try Ethereum.decodeQuantity(text)
            let tip: BigUInt
            do { tip = try await quantity("eth_maxPriorityFeePerGas", []) }
            catch WalletError.rpcRejected(let code) where code == -32601 {
                // Method unavailable: derive the tip only from the node's own gas-price quote.
                let gasPrice = try await quantity("eth_gasPrice", [])
                guard gasPrice >= amount else { throw WalletError.invalid(L("message.node_gas_price_is_below_the_current_base_fee")) }
                tip = gasPrice - amount
            }
            let maxFee = amount * 2 + tip
            guard maxFee > 0, maxFee.bitWidth <= 256 else { throw WalletError.invalid(L("message.node_fee_quote_is_out_of_range")) }
            return EVMFeeQuote(mode: .eip1559, maxPriorityFee: tip, maxFee: maxFee)
        }
        return try await legacyFeeQuote()
    }
    private func legacyFeeQuote() async throws -> EVMFeeQuote {
        let price = try await quantity("eth_gasPrice", [])
        guard price > 0 else { throw WalletError.invalid(L("message.the_node_returned_a_zero_gas_price")) }
        return EVMFeeQuote(mode: .legacy, maxPriorityFee: 0, maxFee: price)
    }
    public func additionalFees(for transaction: EVMTransaction) async throws -> EVMAdditionalFees {
        guard chain.isEVM, transaction.chainID == chain.id else { throw WalletError.invalid(L("message.fee_estimation_network_does_not_match")) }
        return try await EVMFeeEstimator.additional(client: self, transaction: transaction)
    }
    public func prepare(sender: String, recipient: String, amount: String, token: Token? = nil) async throws -> TransactionPreview {
        guard chain.isEVM, chain.canTransfer else { throw WalletError.invalid(L("message.this_network_s_transaction_and_fee_model_is_unsupported")) }
        guard Ethereum.validateAddress(sender), Ethereum.validateAddress(recipient), recipient.lowercased() != "0x" + String(repeating: "0", count: 40) else { throw WalletError.invalid(L("message.receiving_address_is_invalid_or_zero")) }
        if let token, token.chainID != chain.id { throw WalletError.invalid(L("message.token_network_does_not_match")) }
        let units = try Ethereum.parseUnits(amount, decimals: token?.decimals ?? chain.decimals)
        guard units > 0 else { throw WalletError.invalid(L("message.send_amount_must_be_greater_than_zero")) }
        let to = token?.contract ?? recipient
        let data = try token == nil ? Data() : Ethereum.transferData(to: recipient, amount: units)
        let value = token == nil ? units : 0
        return try await prepareTransaction(sender: sender, to: to, value: value, data: data, recipient: recipient, amount: amount, symbol: token?.symbol ?? chain.symbol, token: token, purpose: .transfer)
    }
    public func readContract(_ invocation: ContractInvocation, sender: String? = nil) async throws -> Data {
        guard chain.isEVM, sender == nil || Ethereum.validateAddress(sender!) else { throw WalletError.invalid(L("message.invalid_contract_call_network_or_sender")) }
        try await verifyChain(); try await verifyContract(invocation.contract)
        return try await simulate(invocation, sender: sender)
    }
    public func prepareContract(sender: String, invocation: ContractInvocation) async throws -> TransactionPreview {
        try await prepareContract(sender: sender, invocation: invocation, purpose: .contract(invocation))
    }
    func prepareContract(sender: String, invocation: ContractInvocation, purpose: EVMTransactionPurpose) async throws -> TransactionPreview {
        try await prepareTransaction(sender: sender, to: invocation.contract, value: invocation.nativeValue, data: invocation.data, recipient: invocation.contract, amount: Ethereum.formatUnits(invocation.nativeValue, decimals: chain.decimals, precision: chain.decimals), symbol: chain.symbol, token: nil, purpose: purpose)
    }
    private func prepareTransaction(sender: String, to: String, value: BigUInt, data: Data, recipient: String, amount: String, symbol: String, token: Token?, purpose: EVMTransactionPurpose) async throws -> TransactionPreview {
        guard chain.isEVM, chain.canTransfer, Ethereum.validateAddress(sender) else { throw WalletError.invalid(L("message.this_operation_is_unsupported_for_the_current_network_or_signing")) }
        try await verifyChain()
        if let invocation = purpose.invocation {
            try await verifyContract(invocation.contract)
            let result = try await simulate(invocation, sender: sender)
            if invocation.signature == "approve(address,uint256)", result.count == 32, BigUInt(result) == 0 { throw WalletError.invalid(L("message.the_token_contract_rejected_approval_signing_was_stopped")) }
        }
        let pending = try await quantity("eth_getTransactionCount", [.string(sender), .string("pending")])
        let latest = try await noncePolicy == nil ? pending : quantity("eth_getTransactionCount", [.string(sender), .string("latest")])
        let nonce = try noncePolicy?.next(chainID: chain.id, sender: sender, latest: latest, pending: pending) ?? pending
        let fee = try await feeQuote()
        let mode = fee.mode; let tip = fee.maxPriorityFee; let maxFee = fee.maxFee
        var fields: [String: JSONValue] = ["from": .string(sender), "to": .string(to), "value": .string(Ethereum.quantity(value)), "data": .string("0x" + data.hexString)]
        if mode == .legacy { fields["gasPrice"] = .string(Ethereum.quantity(maxFee)) }
        else { fields["maxFeePerGas"] = .string(Ethereum.quantity(maxFee)); fields["maxPriorityFeePerGas"] = .string(Ethereum.quantity(tip)) }
        let estimated = try await quantity("eth_estimateGas", [.object(fields)])
        let gasLimit = estimated * 120 / 100
        let transaction = try EVMTransaction(chainID: chain.id, nonce: nonce, maxPriorityFee: tip, maxFee: maxFee, gasLimit: gasLimit, to: to, value: value, data: data, mode: mode)
        let additional = try await EVMFeeEstimator.additional(client: self, transaction: transaction)
        let nativeBalance = try await balance(address: sender)
        let reserved = try noncePolicy?.reserved(chainID: chain.id, sender: sender, latest: latest) ?? 0
        guard nativeBalance >= reserved + value + transaction.maximumFee + additional.budget else { throw WalletError.invalid(L("message.insufficient_native_balance_after_reserving_funds_for_pending_local_transactions")) }
        if let token {
            let reservedTokens = try noncePolicy?.reserved(chainID: chain.id, sender: sender, latest: latest, token: token.contract) ?? 0
            guard try await balance(address: sender, token: token) >= Ethereum.parseUnits(amount, decimals: token.decimals) + reservedTokens else { throw WalletError.invalid(L("message.insufficient_token_balance_after_reserving_funds_for_pending_transactions")) }
        }
        let preview = TransactionPreview(transaction: transaction, sender: sender, recipient: Ethereum.checksumAddress(recipient), amount: amount, symbol: symbol, preparedAt: Date(), token: token, additionalFees: additional, purpose: purpose)
        try await enforceTokenReservations(preview, latest: latest)
        return preview
    }
    public func revalidate(_ preview: TransactionPreview) async throws {
        guard chain.isEVM, chain.canTransfer else { throw WalletError.invalid(L("message.sending_is_not_available_on_this_network_yet")) }
        guard !preview.isExpired, preview.transaction.chainID == chain.id else { throw WalletError.invalid(L("message.the_transaction_preview_expired_estimate_again")) }
        try await verifyChain()
        if case .transfer = preview.purpose {
            if let token = preview.token {
                guard token.chainID == chain.id, preview.transaction.to.lowercased() == token.contract.lowercased(), preview.transaction.value == 0,
                      try Ethereum.transferData(to: preview.recipient, amount: Ethereum.parseUnits(preview.amount, decimals: token.decimals)) == preview.transaction.data else { throw WalletError.invalid(L("message.the_token_preview_does_not_match_the_signing_intent")) }
            } else {
                guard preview.transaction.data.isEmpty, preview.transaction.to.lowercased() == preview.recipient.lowercased(), try Ethereum.parseUnits(preview.amount, decimals: chain.decimals) == preview.transaction.value else { throw WalletError.invalid(L("message.the_native_transfer_preview_does_not_match_the_signing_data")) }
            }
        }
        let purpose = preview.replacement == nil ? preview.purpose : preview.purpose.forFeeRevalidation()
        if let invocation = purpose.invocation {
            guard preview.transaction.to.lowercased() == invocation.contract.lowercased(), preview.transaction.data == invocation.data, preview.transaction.value == invocation.nativeValue else { throw WalletError.invalid(L("message.the_contract_preview_does_not_match_the_signing_data")) }
            if case .swap(let quote) = purpose { try await DexClient(rpc: self).revalidate(quote, sender: preview.sender) }
            if case .bridge(let quote, let call) = purpose {
                guard try BridgeClient.evmInvocation(quote) == call else { throw WalletError.invalid(L("message.the_bridge_call_does_not_match_the_approved_preview")) }
                try await BridgeClient.revalidate(quote, sender: preview.sender, endpoint: .evm(self))
            }
            if case .privacy(let intent, let call) = purpose { try await PrivacyPoolClient(rpc: self).revalidate(intent, call: call, sender: preview.sender) }
            try await verifyContract(invocation.contract)
            let result = try await simulate(invocation, sender: preview.sender)
            if invocation.signature == "approve(address,uint256)", result.count == 32, BigUInt(result) == 0 { throw WalletError.invalid(L("message.the_token_contract_rejected_approval_rebuild_the_transaction")) }
        }
        let state = try await nonceState(sender: preview.sender)
        if preview.replacement != nil { try await validateReplacement(preview, latest: state.latest) }
        else {
            let expected = try noncePolicy?.next(chainID: chain.id, sender: preview.sender, latest: state.latest, pending: state.pending) ?? state.pending
            guard expected == preview.transaction.nonce else { throw WalletError.invalid(L("message.the_account_or_local_queue_nonce_changed_rebuild_the_transaction")) }
        }
        let current = try await EVMFeeEstimator.additional(client: self, transaction: preview.transaction)
        guard current.estimated <= preview.additionalFees.budget else { throw WalletError.invalid(L("message.additional_network_fees_exceed_the_preview_budget_estimate_again")) }
        let reserved = try noncePolicy?.reserved(chainID: chain.id, sender: preview.sender, latest: state.latest, excludingNonce: preview.replacement == nil ? nil : preview.transaction.nonce) ?? 0
        guard try await balance(address: preview.sender) >= reserved + preview.transaction.value + preview.totalFeeBudget else { throw WalletError.invalid(L("message.the_balance_or_queue_reservations_changed_rebuild_the_transaction")) }
        if let token = preview.token {
            let reserved = try noncePolicy?.reserved(chainID: chain.id, sender: preview.sender, latest: state.latest, excludingNonce: preview.replacement == nil ? nil : preview.transaction.nonce, token: token.contract) ?? 0
            guard try await balance(address: preview.sender, token: token) >= Ethereum.parseUnits(preview.amount, decimals: token.decimals) + reserved else { throw WalletError.invalid(L("message.the_token_balance_or_queue_reservations_changed")) }
        }
        try await enforceTokenReservations(preview, latest: state.latest)
        let fields = transactionFields(sender: preview.sender, to: preview.transaction.to, value: preview.transaction.value, data: preview.transaction.data, mode: preview.transaction.mode, maxFee: preview.transaction.maxFee, priority: preview.transaction.maxPriorityFee)
        guard preview.transaction.maxFee > 0, try await quantity("eth_estimateGas", [.object(fields)]) <= preview.transaction.gasLimit else { throw WalletError.invalid(L("message.the_current_gas_price_or_execution_budget_is_no_longer")) }
    }
    public func broadcast(_ raw: Data) async throws -> String {
        guard chain.isEVM, chain.canTransfer else { throw WalletError.invalid(L("message.sending_is_not_available_on_this_network_yet")) }
        let localHash = "0x" + raw.keccak256.hexString
        let result = try await call("eth_sendRawTransaction", params: [.string("0x" + raw.hexString)])
        guard result.string?.lowercased() == localHash else { throw WalletError.invalid(L("message.the_node_returned_a_different_transaction_hash_check_on_chain")) }
        return localHash
    }
    public func receipt(hash: String) async throws -> String {
        let data = try Data(strictHex: hash)
        guard data.count == 32 else { throw WalletError.invalid(L("message.invalid_transaction_hash_d7e78dc9")) }
        let result = try await call("eth_getTransactionReceipt", params: [.string(hash)])
        if result == .null { return WalletLocalization.legacy("receipt.pending") }
        guard let status = result["status"]?.string else { throw WalletError.invalid(L("message.the_node_returned_an_invalid_receipt")) }
        return try Ethereum.decodeQuantity(status) == 1 ? WalletLocalization.legacy("receipt.confirmed") : WalletLocalization.legacy("receipt.failed")
    }
    func quantity(_ method: String, _ params: [JSONValue]) async throws -> BigUInt {
        guard let value = try await call(method, params: params).string else { throw WalletError.invalid(L("message.the_node_returned_an_invalid_number")) }
        return try Ethereum.decodeQuantity(value)
    }
    private func enforceTokenReservations(_ preview: TransactionPreview, latest: BigUInt) async throws {
        guard let policy = noncePolicy else { return }
        let record = TransactionRecord.evm(preview, groupID: UUID())
        for spend in record.tokenSpends {
            guard let amount = BigUInt(spend.amount) else { throw WalletError.invalid(L("message.invalid_token_spending_reservation")) }
            let reserved = try policy.reserved(chainID: chain.id, sender: preview.sender, latest: latest, excludingNonce: preview.replacement == nil ? nil : preview.transaction.nonce, token: spend.contract)
            let token = try Token(chainID: chain.id, contract: spend.contract, symbol: "TOKEN", decimals: 0)
            guard try await balance(address: preview.sender, token: token) >= amount + reserved else { throw WalletError.invalid(L("message.other_queued_transactions_have_reserved_the_dex_bridge_token_balance")) }
        }
    }
    func verifyContract(_ address: String) async throws {
        let result = try await call("eth_getCode", params: [.string(address), .string("latest")])
        guard let text = result.string, !(try Data(strictHex: text)).isEmpty else { throw WalletError.invalid(L("message.no_deployed_contract_code_at_the_destination_address")) }
    }
    func simulate(_ invocation: ContractInvocation, sender: String?) async throws -> Data {
        var fields: [String: JSONValue] = ["to": .string(invocation.contract), "data": .string("0x" + invocation.data.hexString), "value": .string(Ethereum.quantity(invocation.nativeValue))]
        if let sender { fields["from"] = .string(sender) }
        let result = try await call("eth_call", params: [.object(fields), .string("latest")])
        guard let text = result.string else { throw WalletError.invalid(L("message.missing_contract_simulation_result")) }; return try Data(strictHex: text)
    }
}
