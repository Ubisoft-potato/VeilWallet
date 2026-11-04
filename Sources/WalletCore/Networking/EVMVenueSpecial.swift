import Foundation
import BigInt

extension EVMVenueClient {
    static let permit2 = "0x000000000022d473030f116ddee9f6b43ac78ba3"
    static let zero = "0x0000000000000000000000000000000000000000"
    static let curveNative = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    func code(_ address: String) async throws {
        _ = try await runtimeCode(address)
    }
    private func runtimeCode(_ address: String) async throws -> Data {
        let result = try await rpc.call("eth_getCode", params: [.string(address), .string("latest")])
        guard let text = result.string, let data = try? Data(strictHex: text), !data.isEmpty else { throw WalletError.invalid(L("message.the_dex_target_has_no_contract_code")) }
        return data
    }
    func verifySpecial(_ venue: DexVenue) async throws -> String {
        try await rpc.verifyChain(); try await code(venue.router)
        if venue.protocol == .curve { return Self.curveNative }
        if venue.protocol == .curveETH { return Self.curveNative }
        if venue.protocol == .uniswapV4 {
            guard let quoter = venue.quoter, let manager = venue.factory else { throw WalletError.invalid(L("message.v4_deployment_missing")) }
            let actual = try ContractABI.address(await rpc.readContract(ContractInvocation(contract: quoter, signature: "poolManager()", arguments: [])))
            guard actual.lowercased() == manager.lowercased() else { throw WalletError.invalid(L("message.v4_poolmanager_differs_from_the_pinned_deployment")) }
            try await code(Self.permit2); return Self.zero
        }
        guard venue.protocol == .balancerV3, let vault = venue.factory else { throw WalletError.invalid(L("message.this_special_dex_deployment_is_unsupported")) }
        // The deployed 20250307 Router has no getVault() (newer source does).
        // Its constructor's Vault is immutable and embedded in the runtime code.
        let runtime = try await runtimeCode(venue.router)
        guard runtime.range(of: try Data(strictHex: vault)) != nil else { throw WalletError.invalid(L("message.the_balancer_router_s_pinned_vault_differs_from_its_runtime")) }
        let permit = try ContractABI.address(await rpc.readContract(ContractInvocation(contract: venue.router, signature: "getPermit2()", arguments: [])))
        guard permit.lowercased() == Self.permit2 else { throw WalletError.invalid(L("message.balancer_permit2_deployment_does_not_match")) }
        return try ContractABI.address(await rpc.readContract(ContractInvocation(contract: venue.router, signature: "getWeth()", arguments: [])))
    }
    func permitAllowance(_ quote: DexQuote, sender: String) async throws -> Bool {
        guard let token = quote.input else { return true }
        let allowance = try await permitAllowance(token: token.contract, spender: quote.invocation.contract, sender: sender)
        return allowance.amount >= quote.amountIn && allowance.expiration >= quote.deadline
    }
    func permitAllowance(token: String, spender: String, sender: String) async throws -> (amount: BigUInt, expiration: BigUInt) {
        let result = try await rpc.readContract(ContractInvocation(contract: Self.permit2, signature: "allowance(address,address,address)", arguments: [sender, token, spender]))
        let fields = try ContractABI.uintWords(result, count: 3)
        guard fields[0].bitWidth <= 160, fields[1].bitWidth <= 48, fields[2].bitWidth <= 48 else { throw WalletError.invalid(L("message.invalid_permit2_allowance_result")) }
        return (fields[0], fields[1])
    }
    func quoteLB(_ venue: DexVenue, path: [String], amount: BigUInt, binStep: UInt32) async throws -> BigUInt {
        guard let factory = venue.factory, path.count == 2, binStep > 0, binStep <= 65535 else { throw WalletError.invalid(L("message.invalid_lb_bin_step")) }
        let pairInfo = try await rpc.readContract(ContractInvocation(contract: factory, signature: "getLBPairInformation(address,address,uint256)", arguments: [path[0], path[1], String(binStep)]))
        let fields = try ContractABI.uintWords(pairInfo, count: 4)
        guard fields[0] == BigUInt(binStep), fields[3] == 0 else { throw WalletError.invalid(L("message.the_lb_pair_is_disabled_or_excluded_from_routing")) }
        let pair = try ContractABI.address(Data(pairInfo[32..<64]))
        let tokenX = try ContractABI.address(await rpc.readContract(ContractInvocation(contract: pair, signature: "getTokenX()", arguments: [])))
        let result = try await rpc.readContract(ContractInvocation(contract: venue.router, signature: "getSwapOut(address,uint128,bool)", arguments: [pair, String(amount), tokenX.lowercased() == path[0].lowercased() ? "true" : "false"]))
        let values = try ContractABI.uintWords(result, count: 3)
        guard values.allSatisfy({ $0.bitWidth <= 128 }), values[0] == 0, values[1] > 0 else { throw WalletError.invalid(L("message.lb_liquidity_cannot_fill_the_complete_input_amount")) }; return values[1]
    }
    func quoteCurve(_ venue: DexVenue, path: [String], amount: BigUInt) async throws -> (amount: BigUInt, indices: String) {
        let count = venue.protocol == .curveETH ? 2 : 3
        var coins: [String] = []
        for i in 0..<count { coins.append(try ContractABI.address(await rpc.readContract(ContractInvocation(contract: venue.router, signature: "coins(uint256)", arguments: [String(i)])))) }
        guard let i = coins.firstIndex(where: { $0.lowercased() == path[0].lowercased() }), let j = coins.firstIndex(where: { $0.lowercased() == path[1].lowercased() }), i != j else { throw WalletError.invalid(L("message.the_asset_is_not_a_coin_in_this_curve_pool")) }
        let output = try ContractABI.uint(await rpc.readContract(ContractInvocation(contract: venue.router, signature: "get_dy(int128,int128,uint256)", arguments: [String(i), String(j), String(amount)])))
        return (output, String(i) + "," + String(j))
    }
    func verifyBalancerPool(_ venue: DexVenue, pool: String, path: [String]) async throws -> String {
        guard let vault = venue.factory, Ethereum.validateAddress(pool), pool.lowercased() != Self.zero else { throw WalletError.invalid(L("message.invalid_balancer_pool_contract_address")) }
        let registered = try ContractABI.uint(await rpc.readContract(ContractInvocation(contract: vault, signature: "isPoolRegistered(address)", arguments: [pool])))
        let initialized = try ContractABI.uint(await rpc.readContract(ContractInvocation(contract: vault, signature: "isPoolInitialized(address)", arguments: [pool])))
        guard registered == 1, initialized == 1 else { throw WalletError.invalid(L("message.the_balancer_pool_is_unregistered_or_uninitialized")) }
        let tokens = try ContractABI.addressArray(await rpc.readContract(ContractInvocation(contract: vault, signature: "getPoolTokens(address)", arguments: [pool])))
        guard path.count == 2, path.allSatisfy({ address in tokens.contains { $0.lowercased() == address.lowercased() } }) else { throw WalletError.invalid(L("message.the_asset_is_not_in_this_balancer_pool")) }
        return Ethereum.checksumAddress(pool)
    }
    func v4Key(_ path: [String], fee: UInt32) throws -> String {
        let spacing: [UInt32: Int] = [100: 1, 500: 10, 3000: 60, 10000: 200]
        guard path.count == 2, let tick = spacing[fee] else { throw WalletError.invalid(L("message.v4_currently_supports_standard_fee_tickspacing_pools_without_hooks")) }
        let ordered = path.sorted { $0.lowercased() < $1.lowercased() }
        return try ContractABI.json([ordered[0], ordered[1], String(fee), String(tick), Self.zero])
    }
    func quoteV4(_ venue: DexVenue, path: [String], amount: BigUInt, fee: UInt32) async throws -> BigUInt {
        guard let quoter = venue.quoter else { throw WalletError.invalid(L("message.v4_quoter_missing")) }
        let key = try v4Key(path, fee: fee), direction = path[0].lowercased() < path[1].lowercased() ? "true" : "false"
        let params = try ContractABI.json([key, direction, String(amount), "0x"])
        let value = try await rpc.readContract(ContractInvocation(contract: quoter, signature: "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))", arguments: [params]))
        return try ContractABI.uintWords(value, count: 2)[0]
    }
    func specialInvocation(_ venue: DexVenue, sender: String, input: Token?, output: Token?, path: [String], amount: BigUInt, minimum: BigUInt, deadline: BigUInt, fee: UInt32, poolID: String?) throws -> ContractInvocation {
        let value = input == nil ? amount : 0
        switch venue.protocol {
        case .liquidityBook:
            guard path.count == 2 else { throw WalletError.invalid(L("message.lb_currently_supports_a_single_pool_route_only")) }
            let route = try ContractABI.json([ContractABI.json([String(fee)]), ContractABI.json(["3"]), ContractABI.json(path)])
            let tuple = "(uint256[],uint8[],address[])"
            if input == nil { return try ContractInvocation(contract: venue.router, signature: "swapExactNATIVEForTokens(uint256," + tuple + ",address,uint256)", arguments: [String(minimum), route, sender, String(deadline)], nativeValue: value) }
            return try ContractInvocation(contract: venue.router, signature: "swapExactTokensFor" + (output == nil ? "NATIVE" : "Tokens") + "(uint256,uint256," + tuple + ",address,uint256)", arguments: [String(amount), String(minimum), route, sender, String(deadline)])
        case .curve, .curveETH:
            guard let indices = poolID?.split(separator: ","), indices.count == 2, let i = Int(indices[0]), let j = Int(indices[1]), i >= 0, j >= 0, i < (venue.protocol == .curve ? 3 : 2), j < (venue.protocol == .curve ? 3 : 2), i != j else { throw WalletError.invalid(L("message.invalid_curve_coin_index")) }
            guard venue.protocol == .curveETH || (input != nil && output != nil) else { throw WalletError.invalid(L("message.curve_3pool_does_not_accept_native_assets")) }
            return try ContractInvocation(contract: venue.router, signature: "exchange(int128,int128,uint256,uint256)", arguments: [String(i), String(j), String(amount), String(minimum)], nativeValue: value)
        case .balancerV3:
            guard let pool = poolID, Ethereum.validateAddress(pool), path.count == 2 else { throw WalletError.invalid(L("message.invalid_balancer_pool_or_route")) }
            return try ContractInvocation(contract: venue.router, signature: "swapSingleTokenExactIn(address,address,address,uint256,uint256,uint256,bool,bytes)", arguments: [pool, path[0], path[1], String(amount), String(minimum), String(deadline), input == nil || output == nil ? "true" : "false", "0x"], nativeValue: value)
        case .uniswapV4:
            let key = try v4Key(path, fee: fee), direction = path[0].lowercased() < path[1].lowercased() ? "true" : "false"
            // Router 2.1.2 includes minHopPriceX36; zero disables that optional
            // relative check. The absolute amountOutMinimum remains mandatory.
            let swap = try ContractABI.json([key, direction, String(amount), String(minimum), "0", "0x"])
            let plans = [try ContractABI.parameters(types: ["((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes)"], arguments: [swap]), try ContractABI.parameters(types: ["address", "uint256"], arguments: [path[0], String(amount)]), try ContractABI.parameters(types: ["address", "uint256"], arguments: [path[1], String(minimum)])]
            let payload = try ContractABI.parameters(types: ["bytes", "bytes[]"], arguments: ["0x060c0f", ContractABI.json(plans.map { "0x" + $0.hexString })])
            var commands = "0x10", inputs = ["0x" + payload.hexString]
            if input == nil {
                // A price-boundary partial fill can settle less than msg.value.
                // Return remaining native input to the same reviewed account.
                commands += "04"
                inputs.append("0x" + (try ContractABI.parameters(types: ["address", "address", "uint256"], arguments: [Self.zero, sender, "0"])).hexString)
            }
            return try ContractInvocation(contract: venue.router, signature: "execute(bytes,bytes[],uint256)", arguments: [commands, ContractABI.json(inputs), String(deadline)], nativeValue: value)
        default: throw WalletError.invalid(L("message.this_dex_encoding_has_not_been_adapted"))
        }
    }
}
