import Foundation
import BigInt

public enum EVMTransactionPurpose: Codable, Sendable {
    case transfer
    case contract(ContractInvocation)
    case swap(DexQuote)
    case bridge(BridgeQuote, ContractInvocation)
    case privacy(PrivacyTransactionIntent, ContractInvocation)
    public var invocation: ContractInvocation? {
        switch self { case .transfer: return nil; case .contract(let call): return call; case .swap(let quote): return quote.invocation; case .bridge(_, let call), .privacy(_, let call): return call }
    }
    public var isSwap: Bool { if case .swap = self { return true }; return false }
    public var title: String { switch self { case .transfer: return L("message.asset_transfer"); case .contract: return L("message.contract_call"); case .swap: return L("message.dex_swap"); case .bridge: return L("message.bridge_b3c670d7"); case .privacy(let intent, _): return intent.kind == .deposit ? L("message.privacy_pool_deposit") : L("message.privacy_pool_withdrawal") } }
}
public struct DexQuote: Codable, Sendable {
    public let chainID: UInt64
    public let input: Token?
    public let output: Token?
    public let amountIn: BigUInt
    public let amountOut: BigUInt
    public let minimumOut: BigUInt
    public let slippageBPS: UInt32
    public let path: [String]
    public let deadline: BigUInt
    public let quotedAt: Date
    public let invocation: ContractInvocation
    public let venueID: String?
    public let fee: UInt32
    public let stable: Bool
    public let poolID: String?
    public var venueName: String { venueID.flatMap(DexCatalog.find)?.name ?? "Uniswap V2" }
    public var approvalSpender: String { venueID.flatMap(DexCatalog.find)?.usesPermit2 == true ? EVMVenueClient.permit2 : invocation.contract }
    init(chainID: UInt64, input: Token?, output: Token?, amountIn: BigUInt, amountOut: BigUInt, minimumOut: BigUInt, slippageBPS: UInt32, path: [String], deadline: BigUInt, quotedAt: Date, invocation: ContractInvocation, venueID: String? = nil, fee: UInt32 = 3000, stable: Bool = false, poolID: String? = nil) {
        self.chainID = chainID; self.input = input; self.output = output; self.amountIn = amountIn; self.amountOut = amountOut; self.minimumOut = minimumOut; self.slippageBPS = slippageBPS; self.path = path; self.deadline = deadline; self.quotedAt = quotedAt; self.invocation = invocation; self.venueID = venueID; self.fee = fee; self.stable = stable; self.poolID = poolID
    }
    public var isExpired: Bool { Date().timeIntervalSince(quotedAt) > 90 }
}
public struct DexClient: Sendable {
    public let rpc: RPCClient
    public init(rpc: RPCClient) { self.rpc = rpc }
    public func verifyVenue(_ id: String) async throws {
        guard let venue = DexCatalog.find(id) else { throw WalletError.invalid(L("message.unknown_dex_deployment")) }
        _ = try await EVMVenueClient(rpc: rpc).verify(venue)
    }
    // Canonical Router02 deployments from uniswap/docs, read at development time.
    public static let deployments: [UInt64: (router: String, factory: String)] = [
        1: ("0x7a250d5630b4cf539739df2c5dacb4c659f2488d", "0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f"),
        11155111: ("0xee567fe1712faf6149d80da1e6934e354124cfe3", "0xf62c03e08ada871a0beb309762e260a7a6a880e6"),
        130: ("0x284f11109359a7e1306c3e447ef14d38400063ff", "0x1f98400000000000000000000000000000000002"),
        42161: ("0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24", "0xf1d7cc64fb4452f05c498126312ebe29f30fbcf9"),
        43114: ("0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24", "0x9e5a52f57b3038f1b8eee45f28b3c1967e22799c"),
        56: ("0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24", "0x8909dc15e40173ff4699343b6eb8132c65e18ec6"),
        8453: ("0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24", "0x8909dc15e40173ff4699343b6eb8132c65e18ec6"),
        10: ("0x4a7b5da61326a6379179b40d00f57e5bbdc962c2", "0x0c3c1c532f1e39edf36be9fe0be1410313e074bf"),
        137: ("0xedf6066a2b290c185783862c7f4776a2c8077ad1", "0x9e5a52f57b3038f1b8eee45f28b3c1967e22799c")
    ]
    public func quote(sender: String, input: Token?, output: Token?, amount: String, slippageBPS: UInt32 = 50, venueID: String? = nil, fee: UInt32 = 3000, stable: Bool = false, viaWrapped: Bool = false, poolID: String? = nil) async throws -> DexQuote {
        if let venueID { return try await EVMVenueClient(rpc: rpc).quote(sender: sender, input: input, output: output, amount: amount, slippage: slippageBPS, venueID: venueID, fee: fee, stable: stable, viaWrapped: viaWrapped, poolID: poolID) }
        guard let deployment = Self.deployments[rpc.chain.id], rpc.chain.isEVM, rpc.chain.canTransfer, Ethereum.validateAddress(sender), slippageBPS > 0, slippageBPS <= 1000 else { throw WalletError.invalid(L("message.no_uniswap_v2_router02_is_configured_on_this_network_or")) }
        for token in [input, output].compactMap({ $0 }) {
            guard token.chainID == rpc.chain.id else { throw WalletError.invalid(L("message.dex_token_network_does_not_match")) }
            let call = try ContractInvocation(contract: token.contract, signature: "decimals()", arguments: [])
            guard try ContractABI.uint(await rpc.readContract(call)) == BigUInt(token.decimals) else { throw WalletError.invalid(L("message.token_decimals_differ_from_the_on_chain_contract_correct_the")) }
        }
        let amountIn = try Ethereum.parseUnits(amount, decimals: input?.decimals ?? rpc.chain.decimals)
        guard amountIn > 0 else { throw WalletError.invalid(L("message.swap_amount_must_be_greater_than_zero")) }
        let factoryCall = try ContractInvocation(contract: deployment.router, signature: "factory()", arguments: [])
        let actualFactory = try ContractABI.address(await rpc.readContract(factoryCall))
        guard actualFactory.lowercased() == deployment.factory else { throw WalletError.invalid(L("message.router_factory_does_not_match_the_bundled_deployment")) }
        let wrapped = try ContractABI.address(await rpc.readContract(ContractInvocation(contract: deployment.router, signature: "WETH()", arguments: [])))
        let path = [input?.contract ?? wrapped, output?.contract ?? wrapped]
        guard path[0].lowercased() != path[1].lowercased() else { throw WalletError.invalid(L("message.input_and_output_assets_are_identical_this_screen_does_not")) }
        let jsonPath = String(data: try JSONEncoder().encode(path), encoding: .utf8)!
        let encoded = try ContractInvocation(contract: deployment.router, signature: "getAmountsOut(uint256,address[])", arguments: [String(amountIn), jsonPath])
        let amounts = try ContractABI.uintArray(await rpc.readContract(encoded), count: path.count)
        guard amounts.first == amountIn, let amountOut = amounts.last, amountOut > 0 else { throw WalletError.invalid(L("message.no_swap_liquidity_is_available")) }
        let minimum = amountOut * BigUInt(10_000 - slippageBPS) / 10_000
        guard minimum > 0 else { throw WalletError.invalid(L("message.minimum_received_amount_must_not_be_zero")) }
        let timestamp = try await blockTimestamp()
        let deadline = timestamp + 300
        let call: ContractInvocation
        if input == nil {
            call = try ContractInvocation(contract: deployment.router, signature: "swapExactETHForTokens(uint256,address[],address,uint256)", arguments: [String(minimum), jsonPath, sender, String(deadline)], nativeValue: amountIn)
        } else {
            call = try ContractInvocation(contract: deployment.router, signature: output == nil ? "swapExactTokensForETH(uint256,uint256,address[],address,uint256)" : "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)", arguments: [String(amountIn), String(minimum), jsonPath, sender, String(deadline)])
        }
        return DexQuote(chainID: rpc.chain.id, input: input, output: output, amountIn: amountIn, amountOut: amountOut, minimumOut: minimum, slippageBPS: slippageBPS, path: path, deadline: deadline, quotedAt: Date(), invocation: call)
    }
    public func allowance(_ quote: DexQuote, sender: String) async throws -> BigUInt {
        guard quote.chainID == rpc.chain.id, Ethereum.validateAddress(sender), let token = quote.input else { return 0 }
        let call = try ContractInvocation(contract: token.contract, signature: "allowance(address,address)", arguments: [sender, quote.approvalSpender])
        return try ContractABI.uint(await rpc.readContract(call))
    }
    public func prepareApproval(_ quote: DexQuote, sender: String) async throws -> TransactionPreview {
        guard quote.chainID == rpc.chain.id, !quote.isExpired, let token = quote.input else { throw WalletError.invalid(L("message.approval_quote_expired_or_the_input_is_not_erc_20")) }
        // Exact amount only. Tokens requiring a reset get an explicit zero-approval transaction first.
        let requirement = try await approvalRequirement(quote, sender: sender)
        let call: ContractInvocation
        switch requirement {
        case .none: throw WalletError.invalid(L("message.approval_is_sufficient_preview_the_swap_directly"))
        case .permit2:
            call = try ContractInvocation(contract: EVMVenueClient.permit2, signature: "approve(address,address,uint160,uint48)", arguments: [token.contract, quote.invocation.contract, String(quote.amountIn), String(quote.deadline)])
        case .token, .reset:
            call = try ContractInvocation(contract: token.contract, signature: "approve(address,uint256)", arguments: [quote.approvalSpender, requirement == .reset ? "0" : String(quote.amountIn)])
        }
        return try await rpc.prepareContract(sender: sender, invocation: call)
    }
    public func approvalRequirement(_ quote: DexQuote, sender: String) async throws -> DexApprovalRequirement {
        guard quote.chainID == rpc.chain.id, Ethereum.validateAddress(sender) else { throw WalletError.invalid(L("message.approval_network_or_account_does_not_match")) }
        guard quote.input != nil else { return .none }
        let current = try await allowance(quote, sender: sender)
        if current < quote.amountIn { return current == 0 ? .token : .reset }
        if quote.venueID.flatMap(DexCatalog.find)?.usesPermit2 == true,
           try await EVMVenueClient(rpc: rpc).permitAllowance(quote, sender: sender) == false { return .permit2 }
        return .none
    }
    public func needsApproval(_ quote: DexQuote, sender: String) async throws -> Bool {
        try await approvalRequirement(quote, sender: sender) != .none
    }
    public func prepareSwap(_ quote: DexQuote, sender: String) async throws -> TransactionPreview {
        try await revalidate(quote, sender: sender)
        return try await rpc.prepareContract(sender: sender, invocation: quote.invocation, purpose: .swap(quote))
    }
    func revalidate(_ quote: DexQuote, sender: String) async throws {
        if quote.venueID != nil { try await EVMVenueClient(rpc: rpc).revalidate(quote, sender: sender); return }
        guard quote.chainID == rpc.chain.id, !quote.isExpired, let deployment = Self.deployments[quote.chainID], quote.invocation.contract.lowercased() == deployment.router,
              quote.deadline > (try await blockTimestamp()) else { throw WalletError.invalid(L("message.the_dex_quote_or_transaction_deadline_expired_get_a_fresh")) }
        if let token = quote.input {
            guard try await rpc.balance(address: sender, token: token) >= quote.amountIn else { throw WalletError.invalid(L("message.insufficient_swap_input_token_balance")) }
            guard try await allowance(quote, sender: sender) >= quote.amountIn else { throw WalletError.invalid(L("message.insufficient_allowance_confirm_approval_separately_then_requote_after_confirmation")) }
        }
    }
    private func blockTimestamp() async throws -> BigUInt {
        let block = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        guard let text = block["timestamp"]?.string else { throw WalletError.invalid(L("message.the_node_did_not_return_a_block_timestamp")) }
        let timestamp = try Ethereum.decodeQuantity(text)
        let now = BigUInt(max(0, Int(Date().timeIntervalSince1970)))
        guard timestamp <= now + 300, now <= timestamp + 300 else { throw WalletError.invalid(L("message.the_node_block_timestamp_differs_too_much_from_the_local")) }; return timestamp
    }
}
