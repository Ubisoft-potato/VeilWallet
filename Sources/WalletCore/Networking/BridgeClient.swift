import Foundation
import BigInt

extension BridgeClient {
    static let sendTuple = "(uint32,bytes32,uint256,uint256,bytes,bytes,bytes)"
    static let oftBridgeSignature = "bridge(address,uint256,bytes32,uint256,uint256,uint256,uint256)"
    public func quote(sourceID: String, destinationID: String, sender: String, recipient: String, amount: String, slippageBP: UInt32 = 50) async throws -> BridgeQuote {
        guard let source = BridgeCatalog.find(sourceID), let destination = BridgeCatalog.find(destinationID),
              BridgeCatalog.destinations(for: source).contains(destination), (1...1000).contains(slippageBP) else { throw WalletError.invalid(L("message.no_supported_direct_bridge_route_tron_and_bsc_require_separate")) }
        let from = try endpoint(source.networkID), to = try endpoint(destination.networkID)
        _ = try BridgeEndpoint.evmAddress(sender, chain: from.chain)
        _ = try BridgeEndpoint.word(recipient, networkID: destination.networkID)
        let units = try Ethereum.parseUnits(amount, decimals: source.decimals)
        guard units > 0, units.bitWidth <= 128 else { throw WalletError.invalid(L("message.invalid_bridge_amount")) }
        let reads = BridgeReadSession(from), remoteReads = BridgeReadSession(to)
        async let sourceState = Self.verify(source, destination: destination, endpoint: reads)
        async let targetState = Self.verify(destination, destination: source, endpoint: remoteReads)
        let (state, remote) = try await (sourceState, targetState)
        if source.bridgeProtocol == .allbridgeOFT {
            let peer = try await reads.read(state.oft, "peers(uint32)", [String(destination.endpointID)])
            let expectedPeer = try Data(strictHex: BridgeEndpoint.word(remote.oft, networkID: destination.networkID))
            guard peer == expectedPeer else { throw WalletError.invalid(L("message.the_oft_destination_peer_does_not_match_the_pinned_destination")) }
        }
        let sent: BigUInt, expectedLD: BigUInt, minimum: BigUInt, fee: BigUInt
        if source.bridgeProtocol == .allbridgeOFT {
            let adminFee = state.admin == 0 ? 0 : max(1, units * BigUInt(state.admin) / 10_000)
            guard units > adminFee else { throw WalletError.invalid(L("message.the_amount_cannot_cover_the_bridge_s_token_fee")) }
            sent = units - adminFee
            minimum = sent - sent * BigUInt(slippageBP) / 10_000
            expectedLD = try await reads.uint(source.contract, "receiveAmount(address,uint256,uint256)", [BridgeEndpoint.evmAddress(source.tokenAddress, chain: from.chain), String(destination.protocolID), String(units)])
            fee = try await reads.uint(source.contract, "relayerFee(address,uint256,uint256)", [BridgeEndpoint.evmAddress(source.tokenAddress, chain: from.chain), String(destination.protocolID), String(sent)])
        } else {
            let params = try Self.sendParam(destination: destination, recipient: recipient, amount: units, minimum: 0)
            let receipt = try Self.oftReceipt(await reads.read(source.contract, "quoteOFT(" + Self.sendTuple + ")", [params]))
            guard units >= receipt.minimum, units <= receipt.maximum, receipt.sent > 0, receipt.sent <= units else { throw WalletError.invalid(L("message.the_stargate_amount_is_outside_the_available_liquidity_range")) }
            sent = receipt.sent; expectedLD = receipt.received
            let sharedStep = BigUInt(10).power(source.decimals - 6)
            minimum = (expectedLD * BigUInt(10_000 - slippageBP) / 10_000) / sharedStep * sharedStep
            let send = try Self.sendParam(destination: destination, recipient: recipient, amount: units, minimum: minimum)
            let fees = try ContractABI.uintWords(await reads.read(source.contract, "quoteSend(" + Self.sendTuple + ",bool)", [send, "false"]), count: 2)
            guard fees[1] == 0 else { throw WalletError.invalid(L("message.this_screen_permits_native_asset_message_fees_only")) }; fee = fees[0]
        }
        guard expectedLD > 0, expectedLD.bitWidth <= 128, minimum > 0, expectedLD >= minimum, fee > 0, fee.bitWidth <= (from.chain.family == .tron ? 63 : 128) else { throw WalletError.invalid(L("message.invalid_bridge_quote_minimum_amount_or_message_fee")) }
        let out = try Self.convert(expectedLD, from: source.decimals, to: destination.decimals)
        let minimumOut = try Self.convert(minimum, from: source.decimals, to: destination.decimals)
        return BridgeQuote(source: source, destination: destination, sender: sender, recipient: recipient, amount: units, expectedDestination: out, minimumDestination: minimumOut, nativeFee: fee, adminFeeBP: state.admin, slippageBP: slippageBP, sourceOFT: state.oft, destinationOFT: remote.oft, sendAmount: sent, minimumLD: minimum, quotedAt: Date())
    }
    public func needsApproval(_ quote: BridgeQuote) async throws -> Bool {
        guard !quote.isExpired else { throw WalletError.invalid(L("message.bridge_quote_expired")) }
        return try await endpoint(quote.source.networkID).allowance(owner: quote.sender, token: quote.source.token, spender: quote.source.contract) < quote.amount
    }
    public func prepareApproval(_ quote: BridgeQuote) async throws -> BridgeTransactionPlan {
        let from = try endpoint(quote.source.networkID)
        try Self.validateIntent(quote, sender: quote.sender, chain: from.chain)
        let current = try await from.allowance(owner: quote.sender, token: quote.source.token, spender: quote.source.contract)
        guard current < quote.amount else { throw WalletError.invalid(L("message.allowance_is_already_sufficient_get_a_fresh_quote")) }
        let args = try [BridgeEndpoint.evmAddress(quote.source.contract, chain: from.chain), current == 0 ? String(quote.amount) : "0"]
        switch from {
        case .evm(let rpc): return .evm(try await rpc.prepareContract(sender: quote.sender, invocation: ContractInvocation(contract: quote.source.tokenAddress, signature: "approve(address,uint256)", arguments: args)))
        case .tron(let client): return .tron(try await client.prepare(sender: quote.sender, invocation: TronInvocation(contract: quote.source.tokenAddress, signature: "approve(address,uint256)", arguments: args)))
        }
    }
    public func prepareTransfer(_ quote: BridgeQuote) async throws -> BridgeTransactionPlan {
        let from = try endpoint(quote.source.networkID)
        try await Self.revalidate(quote, sender: quote.sender, endpoint: from)
        switch from {
        case .evm(let rpc):
            let call = try Self.evmInvocation(quote)
            return .evm(try await rpc.prepareContract(sender: quote.sender, invocation: call, purpose: .bridge(quote, call)))
        case .tron(let client): return .tron(try await client.prepare(sender: quote.sender, invocation: Self.tronInvocation(quote), bridge: quote))
        }
    }
    static func verify(_ deployment: BridgeDeployment, destination: BridgeDeployment, endpoint: BridgeReadSession) async throws -> (oft: String, admin: UInt32) {
        guard BridgeCatalog.find(deployment.id) == deployment, endpoint.chain.id == deployment.networkID else { throw WalletError.invalid(L("message.bridge_deployment_is_not_pinned")) }
        guard try await endpoint.uint(deployment.tokenAddress, "decimals()") == BigUInt(deployment.decimals) else { throw WalletError.invalid(L("message.bridge_token_decimals_differ_from_the_pinned_catalog")) }
        if deployment.bridgeProtocol == .stargateV2 {
            let actual = try await endpoint.address(deployment.contract, "token()")
            guard BridgeEndpoint.same(actual, deployment.tokenAddress, chain: endpoint.chain), try await endpoint.uint(deployment.contract, "sharedDecimals()") == 6 else { throw WalletError.invalid(L("message.stargate_token_shared_decimals_do_not_match")) }
            return (deployment.contract, 0)
        }
        guard try await endpoint.uint(deployment.contract, "chainId()") == BigUInt(deployment.protocolID), try await endpoint.uint(deployment.contract, "getEidByChainId(uint256)", [String(destination.protocolID)]) == BigUInt(destination.endpointID) else { throw WalletError.invalid(L("message.allbridge_network_layerzero_destination_does_not_match")) }
        let args = try [BridgeEndpoint.evmAddress(deployment.tokenAddress, chain: endpoint.chain), String(destination.protocolID)]
        let oft = try await endpoint.address(deployment.contract, "oftAddress(address,uint256)", args)
        guard BridgeEndpoint.same(try await endpoint.address(oft, "token()"), deployment.tokenAddress, chain: endpoint.chain), try await endpoint.uint(oft, "sharedDecimals()") == 6 else { throw WalletError.invalid(L("message.allbridge_oft_token_shared_decimals_do_not_match")) }
        let admin = try await endpoint.uint(deployment.contract, "adminFeeShareBP(address)", [BridgeEndpoint.evmAddress(deployment.tokenAddress, chain: endpoint.chain)])
        guard let bp = UInt32(exactly: admin), bp < 10_000 else { throw WalletError.invalid(L("message.invalid_bridge_token_fee")) }
        return (oft, bp)
    }
    static func validateIntent(_ quote: BridgeQuote, sender: String, chain: Chain) throws {
        guard !quote.isExpired, quote.source.networkID == chain.id, BridgeCatalog.find(quote.source.id) == quote.source,
              BridgeCatalog.destinations(for: quote.source).contains(quote.destination), BridgeEndpoint.same(sender, quote.sender, chain: chain), quote.amount > 0, (1...1000).contains(quote.slippageBP) else { throw WalletError.invalid(L("message.bridge_preview_expired_or_the_account_route_changed")) }
        _ = try BridgeEndpoint.word(quote.recipient, networkID: quote.destination.networkID)
    }
    static func revalidate(_ quote: BridgeQuote, sender: String, endpoint: BridgeEndpoint) async throws {
        try validateIntent(quote, sender: sender, chain: endpoint.chain)
        let reads = BridgeReadSession(endpoint)
        let state = try await verify(quote.source, destination: quote.destination, endpoint: reads)
        guard BridgeEndpoint.same(state.oft, quote.sourceOFT, chain: endpoint.chain), state.admin == quote.adminFeeBP else { throw WalletError.invalid(L("message.bridge_fees_or_the_oft_route_changed_get_a_fresh")) }
        let token = try quote.source.token
        guard try await reads.balance(sender, token: token) >= quote.amount, try await reads.allowance(owner: sender, token: token, spender: quote.source.contract) >= quote.amount else { throw WalletError.invalid(L("message.insufficient_bridge_balance_or_exact_approval_allowance")) }
        if quote.source.bridgeProtocol == .allbridgeOFT {
            let peer = try await reads.read(state.oft, "peers(uint32)", [String(quote.destination.endpointID)])
            let expectedPeer = try Data(strictHex: BridgeEndpoint.word(quote.destinationOFT, networkID: quote.destination.networkID))
            guard peer == expectedPeer else { throw WalletError.invalid(L("message.the_oft_destination_peer_changed")) }
            let current = try await reads.uint(quote.source.contract, "relayerFee(address,uint256,uint256)", [BridgeEndpoint.evmAddress(token.contract, chain: endpoint.chain), String(quote.destination.protocolID), String(quote.sendAmount)])
            guard current <= quote.nativeFee else { throw WalletError.invalid(L("message.the_bridge_message_fee_exceeds_the_preview")) }
        } else {
            let param = try sendParam(destination: quote.destination, recipient: quote.recipient, amount: quote.amount, minimum: quote.minimumLD)
            let receipt = try oftReceipt(await reads.read(quote.source.contract, "quoteOFT(" + sendTuple + ")", [param]))
            let fees = try ContractABI.uintWords(await reads.read(quote.source.contract, "quoteSend(" + sendTuple + ",bool)", [param, "false"]), count: 2)
            guard receipt.received >= quote.minimumLD, receipt.sent <= quote.amount, fees[0] <= quote.nativeFee, fees[1] == 0 else { throw WalletError.invalid(L("message.stargate_amount_or_fees_exceed_the_preview")) }
        }
    }
    static func arguments(_ quote: BridgeQuote) throws -> (signature: String, arguments: [String]) {
        if quote.source.bridgeProtocol == .allbridgeOFT {
            let token = try quote.source.networkID == TronAddress.chainID ? TronAddress.evm(quote.source.tokenAddress) : quote.source.tokenAddress
            return (oftBridgeSignature, [token, String(quote.amount), try BridgeEndpoint.word(quote.recipient, networkID: quote.destination.networkID), String(quote.destination.protocolID), "0", "0", String(quote.slippageBP)])
        }
        return ("sendToken(" + sendTuple + ",(uint256,uint256),address)", [try sendParam(destination: quote.destination, recipient: quote.recipient, amount: quote.amount, minimum: quote.minimumLD), try ContractABI.json([String(quote.nativeFee), "0"]), quote.sender])
    }
    static func evmInvocation(_ quote: BridgeQuote) throws -> ContractInvocation { let a = try arguments(quote); return try .init(contract: quote.source.contract, signature: a.signature, arguments: a.arguments, nativeValue: quote.nativeFee) }
    static func tronInvocation(_ quote: BridgeQuote) throws -> TronInvocation { let a = try arguments(quote); return try .init(contract: quote.source.contract, signature: a.signature, arguments: a.arguments, callValue: quote.nativeFee) }
    static func sendParam(destination: BridgeDeployment, recipient: String, amount: BigUInt, minimum: BigUInt) throws -> String {
        try ContractABI.json([String(destination.endpointID), BridgeEndpoint.word(recipient, networkID: destination.networkID), String(amount), String(minimum), "0x", "0x", "0x"])
    }
    static func convert(_ amount: BigUInt, from: Int, to: Int) throws -> BigUInt {
        guard (6...36).contains(from), (6...36).contains(to) else { throw WalletError.invalid(L("message.bridge_precision_exceeds_the_supported_range")) }
        if from > to { let divisor = BigUInt(10).power(from - to); guard amount % divisor == 0 else { throw WalletError.invalid(L("message.the_bridge_returned_undeclared_shared_decimal_rounding")) }; return amount / divisor }
        return amount * BigUInt(10).power(to - from)
    }
    static func oftReceipt(_ data: Data) throws -> (minimum: BigUInt, maximum: BigUInt, sent: BigUInt, received: BigUInt) {
        guard data.count >= 192, data.count <= 8192, data.count % 32 == 0, BigUInt(data[64..<96]) == 160, BigUInt(data[160..<192]) <= 16 else { throw WalletError.invalid(L("message.invalid_oft_quote_data")) }
        let minimum = BigUInt(data[0..<32]), maximum = BigUInt(data[32..<64]), sent = BigUInt(data[96..<128]), received = BigUInt(data[128..<160])
        guard minimum <= maximum, sent > 0, received > 0, sent.bitWidth <= 128, received.bitWidth <= 128 else { throw WalletError.invalid(L("message.no_valid_oft_quote_is_available")) }
        return (minimum, maximum, sent, received)
    }
}
