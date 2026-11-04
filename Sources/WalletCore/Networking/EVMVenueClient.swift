import Foundation
import BigInt

struct EVMVenueClient: Sendable {
    let rpc: RPCClient
    func quote(sender: String, input: Token?, output: Token?, amount: String, slippage: UInt32, venueID: String, fee: UInt32, stable: Bool, viaWrapped: Bool, poolID: String?) async throws -> DexQuote {
        guard let venue = DexCatalog.find(venueID), venue.chainID == rpc.chain.id, rpc.chain.isEVM, rpc.chain.canTransfer, Ethereum.validateAddress(sender), (1...1000).contains(slippage), input?.contract != output?.contract else { throw WalletError.invalid(L("message.invalid_dex_network_asset_or_slippage")) }
        for token in [input, output].compactMap({ $0 }) {
            guard token.chainID == venue.chainID, try await ContractABI.uint(rpc.readContract(ContractInvocation(contract: token.contract, signature: "decimals()", arguments: []))) == BigUInt(token.decimals) else { throw WalletError.invalid(L("message.token_decimals_or_network_differ_from_on_chain_data")) }
        }
        let units = try Ethereum.parseUnits(amount, decimals: input?.decimals ?? rpc.chain.decimals)
        guard units > 0, units.bitWidth <= 128 else { throw WalletError.invalid(L("message.swap_amount_must_be_positive_and_within_the_protocol_range")) }
        let wrapped = try await verify(venue)
        var path = [input?.contract ?? wrapped, output?.contract ?? wrapped].map(Ethereum.checksumAddress)
        guard path[0] != path[1] else { throw WalletError.invalid(L("message.input_and_output_are_identical_standalone_wrapping_or_unwrapping_is")) }
        if viaWrapped, input != nil, output != nil, !path.contains(where: { $0.lowercased() == wrapped.lowercased() }) { path.insert(Ethereum.checksumAddress(wrapped), at: 1) }
        let quotePath = path
        let amountOut: BigUInt
        var context = poolID
        var selectedFee = fee
        switch venue.protocol {
        case .v2, .v2Avax:
            let value = try await rpc.readContract(ContractInvocation(contract: venue.router, signature: "getAmountsOut(uint256,address[])", arguments: [String(units), ContractABI.json(path)]))
            let amounts = try ContractABI.uintArray(value, count: path.count)
            guard amounts.first == units else { throw WalletError.invalid(L("message.dex_input_amount_does_not_match")) }; amountOut = amounts.last!
        case .solidly:
            let route = try routes(path, venue: venue, stable: stable)
            let value = try await rpc.readContract(ContractInvocation(contract: venue.router, signature: "getAmountsOut(uint256,(address,address,bool,address)[])", arguments: [String(units), route]))
            let amounts = try ContractABI.uintArray(value, count: path.count)
            guard amounts.first == units else { throw WalletError.invalid(L("message.solidly_input_amount_does_not_match")) }; amountOut = amounts.last!
        case .v3, .v3Router02, .algebra, .slipstream:
            guard let quoter = venue.quoter else { throw WalletError.invalid(L("message.quote_contract_is_not_configured")) }
            let fees: [UInt32] = venue.protocol == .algebra ? [0] : (fee > 0 ? [fee] : (venue.protocol == .slipstream ? [1, 10, 50, 100, 200] : (venue.id.hasPrefix("pancake") ? [100, 500, 2500, 10000] : [100, 500, 3000, 10000])))
            let result = try await bestFee(fees) { rate in
                let encoded = try packedPath(quotePath, protocol: venue.protocol, fee: rate)
                let value = try await rpc.readContract(ContractInvocation(contract: quoter, signature: "quoteExactInput(bytes,uint256)", arguments: ["0x" + encoded.hexString, String(units)]))
                guard value.count >= 32, value.count <= 2048, value.count % 32 == 0 else { throw WalletError.invalid(L("message.invalid_dex_quote_result")) }
                return BigUInt(value.prefix(32))
            }
            amountOut = result.amount; selectedFee = result.fee
        case .liquidityBook:
            guard !viaWrapped, path.count == 2 else { throw WalletError.invalid(L("message.liquidity_book_currently_supports_a_single_pool_route_only")) }
            let result = try await quoteLBAutomatic(venue, path: path, amount: units, binStep: fee)
            amountOut = result.amount; selectedFee = result.fee
        case .curve, .curveETH:
            guard !viaWrapped, path.count == 2 else { throw WalletError.invalid(L("message.curve_currently_supports_direct_pool_coin_swaps_only")) }
            let result = try await quoteCurve(venue, path: path, amount: units); amountOut = result.amount; context = result.indices
        case .balancerV3:
            guard !viaWrapped, path.count == 2, let poolID else { throw WalletError.invalid(L("message.select_a_balancer_pool_contract_address")) }
            context = try await verifyBalancerPool(venue, pool: poolID, path: path)
            amountOut = try ContractABI.uint(await rpc.readContract(ContractInvocation(contract: venue.router, signature: "querySwapSingleTokenExactIn(address,address,address,uint256,address,bytes)", arguments: [context!, path[0], path[1], String(units), sender, "0x"])))
        case .uniswapV4:
            guard !viaWrapped, path.count == 2 else { throw WalletError.invalid(L("message.uniswap_v4_currently_supports_a_single_hookless_pool_only")) }
            let result = try await bestFee(fee > 0 ? [fee] : [100, 500, 3000, 10000]) { try await quoteV4(venue, path: quotePath, amount: units, fee: $0) }
            amountOut = result.amount; selectedFee = result.fee
        default: throw WalletError.invalid(L("message.this_path_is_not_adapted_for_the_selected_dex_protocol"))
        }
        let minimum = amountOut * BigUInt(10_000 - slippage) / 10_000
        guard minimum > 0 else { throw WalletError.invalid(L("message.minimum_received_amount_must_be_greater_than_zero")) }
        let now = try await timestamp()
        var deadline = now + 300
        if venue.usesPermit2, let input {
            let existing = try await permitAllowance(token: input.contract, spender: venue.router, sender: sender)
            // Requoting after confirmation must not demand an ever-later
            // approval. Keep the swap inside the existing grant's lifetime,
            // provided at least the full 90-second review window remains.
            if existing.amount >= units, existing.expiration >= now + 90 { deadline = min(deadline, existing.expiration) }
        }
        let call = try invocation(venue: venue, sender: sender, input: input, output: output, path: path, amount: units, minimum: minimum, deadline: deadline, fee: selectedFee, stable: stable, poolID: context)
        return DexQuote(chainID: venue.chainID, input: input, output: output, amountIn: units, amountOut: amountOut, minimumOut: minimum, slippageBPS: slippage, path: path, deadline: deadline, quotedAt: Date(), invocation: call, venueID: venue.id, fee: selectedFee, stable: stable, poolID: context)
    }
    func revalidate(_ quote: DexQuote, sender: String) async throws {
        guard let id = quote.venueID, let venue = DexCatalog.find(id), venue.chainID == rpc.chain.id, !quote.isExpired, quote.deadline > (try await timestamp()) else { throw WalletError.invalid(L("message.dex_preview_expired_or_deployment_network_changed")) }
        let wrapped = try await verify(venue)
        guard quote.path.count >= 2, quote.path.count <= 3,
              quote.path.first?.lowercased() == (quote.input?.contract ?? wrapped).lowercased(),
              quote.path.last?.lowercased() == (quote.output?.contract ?? wrapped).lowercased(),
              quote.path.count != 3 || quote.path[1].lowercased() == wrapped.lowercased() else { throw WalletError.invalid(L("message.dex_path_does_not_match_the_current_input_output_assets")) }
        if venue.protocol == .balancerV3 { guard let pool = quote.poolID else { throw WalletError.invalid(L("message.balancer_pool_missing")) }; _ = try await verifyBalancerPool(venue, pool: pool, path: quote.path) }
        let rebuilt = try invocation(venue: venue, sender: sender, input: quote.input, output: quote.output, path: quote.path, amount: quote.amountIn, minimum: quote.minimumOut, deadline: quote.deadline, fee: quote.fee, stable: quote.stable, poolID: quote.poolID)
        guard rebuilt == quote.invocation else { throw WalletError.invalid(L("message.dex_path_recipient_or_amount_differs_from_the_preview")) }
        if let token = quote.input {
            guard try await rpc.balance(address: sender, token: token) >= quote.amountIn else { throw WalletError.invalid(L("message.insufficient_swap_input_assets")) }
            guard try await DexClient(rpc: rpc).needsApproval(quote, sender: sender) == false else { throw WalletError.invalid(L("message.approve_the_exact_allowance_separately_then_requote_after_confirmation")) }
        }
    }
    func verify(_ venue: DexVenue) async throws -> String {
        guard venue.chainID == rpc.chain.id, DexCatalog.find(venue.id) == venue else { throw WalletError.invalid(L("message.dex_deployment_is_not_pinned")) }
        if [.uniswapV4, .balancerV3, .curve, .curveETH].contains(venue.protocol) { return try await verifySpecial(venue) }
        let factoryGetter = venue.protocol == .solidly ? "defaultFactory()" : (venue.protocol == .liquidityBook ? "getFactory()" : "factory()")
        if let factory = venue.factory {
            let actual = try ContractABI.address(await rpc.readContract(ContractInvocation(contract: venue.router, signature: factoryGetter, arguments: [])))
            guard actual.lowercased() == factory.lowercased() else { throw WalletError.invalid(L("message.dex_factory_differs_from_the_pinned_deployment")) }
        }
        let getter: String
        switch venue.protocol {
        case .v2: getter = "WETH()"
        case .v2Avax: getter = "WAVAX()"
        case .solidly: getter = "weth()"
        case .algebra: getter = "WNativeToken()"
        case .liquidityBook: getter = "getWNATIVE()"
        default: getter = "WETH9()"
        }
        let wrapped = try ContractABI.address(await rpc.readContract(ContractInvocation(contract: venue.router, signature: getter, arguments: [])))
        if let pinned = venue.wrapped { guard wrapped.lowercased() == pinned.lowercased() else { throw WalletError.invalid(L("message.dex_wrapped_asset_differs_from_the_pinned_deployment")) } }
        return wrapped
    }
    private func routes(_ path: [String], venue: DexVenue, stable: Bool) throws -> String {
        guard let factory = venue.factory, (2...3).contains(path.count) else { throw WalletError.invalid(L("message.invalid_solidly_path")) }
        return try ContractABI.json((0..<(path.count - 1)).map { try ContractABI.json([path[$0], path[$0 + 1], stable ? "true" : "false", factory]) })
    }
    func packedPath(_ path: [String], protocol kind: DexProtocol, fee: UInt32) throws -> Data {
        guard (2...3).contains(path.count), path.allSatisfy(Ethereum.validateAddress) else { throw WalletError.invalid(L("message.invalid_dex_path")) }
        if kind != .algebra { guard fee > 0, fee < (kind == .slipstream ? 8_388_608 : 1_000_000) else { throw WalletError.invalid(L("message.invalid_v3_fee_tick_spacing")) } }
        var data = try Data(strictHex: path[0])
        for address in path.dropFirst() {
            if kind != .algebra { data += Data([UInt8((fee >> 16) & 255), UInt8((fee >> 8) & 255), UInt8(fee & 255)]) }
            data += try Data(strictHex: address)
        }
        return data
    }
    func invocation(venue: DexVenue, sender: String, input: Token?, output: Token?, path: [String], amount: BigUInt, minimum: BigUInt, deadline: BigUInt, fee: UInt32, stable: Bool, poolID: String? = nil) throws -> ContractInvocation {
        guard path.first?.lowercased() == (input?.contract.lowercased() ?? path.first?.lowercased()), path.last?.lowercased() == (output?.contract.lowercased() ?? path.last?.lowercased()), amount > 0, minimum > 0, Ethereum.validateAddress(sender) else { throw WalletError.invalid(L("message.invalid_dex_input_output_or_recipient")) }
        let value = input == nil ? amount : 0
        if [.liquidityBook, .curve, .curveETH, .balancerV3, .uniswapV4].contains(venue.protocol) { return try specialInvocation(venue, sender: sender, input: input, output: output, path: path, amount: amount, minimum: minimum, deadline: deadline, fee: fee, poolID: poolID) }
        switch venue.protocol {
        case .v2, .v2Avax, .solidly:
            let solid = venue.protocol == .solidly, avax = venue.protocol == .v2Avax
            let route = try solid ? routes(path, venue: venue, stable: stable) : ContractABI.json(path)
            let routeType = solid ? "(address,address,bool,address)[]" : "address[]"
            let nativeName = avax ? "AVAX" : "ETH"
            let signature: String, args: [String]
            if input == nil { signature = "swapExact" + nativeName + "ForTokens(uint256," + routeType + ",address,uint256)"; args = [String(minimum), route, sender, String(deadline)] }
            else { signature = "swapExactTokensFor" + (output == nil ? nativeName : "Tokens") + "(uint256,uint256," + routeType + ",address,uint256)"; args = [String(amount), String(minimum), route, sender, String(deadline)] }
            return try ContractInvocation(contract: venue.router, signature: signature, arguments: args, nativeValue: value)
        case .v3, .v3Router02, .algebra, .slipstream:
            let encoded = try packedPath(path, protocol: venue.protocol, fee: fee)
            let recipient = output == nil ? venue.router : sender
            var fields = ["0x" + encoded.hexString, recipient]
            if venue.protocol != .v3Router02 { fields.append(String(deadline)) }
            fields += [String(amount), String(minimum)]
            let tuple = venue.protocol == .v3Router02 ? "(bytes,address,uint256,uint256)" : "(bytes,address,uint256,uint256,uint256)"
            let swap = try ContractInvocation(contract: venue.router, signature: "exactInput(" + tuple + ")", arguments: [ContractABI.json(fields)])
            var calls = ["0x" + swap.data.hexString]
            if output == nil {
                let signature = venue.protocol == .algebra ? "unwrapWNativeToken(uint256,address)" : "unwrapWETH9(uint256,address)"
                calls.append("0x" + (try ContractInvocation(contract: venue.router, signature: signature, arguments: [String(minimum), sender])).data.hexString)
            }
            if input == nil {
                let signature = venue.protocol == .algebra ? "refundNativeToken()" : "refundETH()"
                calls.append("0x" + (try ContractInvocation(contract: venue.router, signature: signature, arguments: [])).data.hexString)
            }
            if venue.protocol == .v3Router02 { return try ContractInvocation(contract: venue.router, signature: "multicall(uint256,bytes[])", arguments: [String(deadline), ContractABI.json(calls)], nativeValue: value) }
            if calls.count == 1 { return try ContractInvocation(contract: venue.router, signature: swap.signature, arguments: swap.arguments, nativeValue: value) }
            return try ContractInvocation(contract: venue.router, signature: "multicall(bytes[])", arguments: [ContractABI.json(calls)], nativeValue: value)
        default: throw WalletError.invalid(L("message.this_dex_encoding_is_unsupported"))
        }
    }
    func timestamp() async throws -> BigUInt {
        let block = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        guard let text = block["timestamp"]?.string else { throw WalletError.invalid(L("message.block_timestamp_missing")) }
        let value = try Ethereum.decodeQuantity(text), now = BigUInt(max(0, Int(Date().timeIntervalSince1970)))
        guard value <= now + 300, now <= value + 300 else { throw WalletError.invalid(L("message.the_node_is_not_synced_or_its_clock_is_wrong")) }; return value
    }
}
