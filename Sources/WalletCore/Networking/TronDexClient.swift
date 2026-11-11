import Foundation
import BigInt

public enum TronDexMode: String, CaseIterable, Sendable {
    case v2, smart
    public var name: String { self == .v2 ? L("message.sunswap_v2_direct_on_chain_quote") : "SUN · V1/V2/V3/V4 / SunCurve / PSM" }
}
public struct TronDexHop: Sendable, Equatable {
    public let from: String; public let to: String; public let version: String; public let fee: UInt32
    public let parameters: String?
}
public struct TronDexQuote: Sendable {
    public let mode: TronDexMode; public let chainID: UInt64; public let sender: String
    public let input: Token?; public let output: Token?
    public let amountIn: BigUInt; public let amountOut: BigUInt; public let minimumOut: BigUInt
    public let slippageBPS: UInt32; public let deadline: BigUInt; public let quotedAt: Date
    public let hops: [TronDexHop]; public let invocation: TronInvocation
    public var isExpired: Bool { Date().timeIntervalSince(quotedAt) > 90 }
}
public struct TronDexClient: Sendable {
    public let client: TronContractClient
    public init(client: TronContractClient) { self.client = client }
    public static let wrapped = "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR"
    public static let native = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"
    public static let v2Router = "TNJVzGqKBWkJxJB5XYSqGAwUTV15U24pPq"
    public static let v2Factory = "TKWJdrQkqHisa1X8HUdHEfREvTzw4pMAaY"
    // Pinned to sun-protocol/sun-kit src/constants.ts and universal-router-sdk.
    public static let universalRouter = "TSJEtPuqHpvSaVnSwvCsngaeBxrGUzp95Q"
    public static let permit2 = "TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9"
    static let thisAddress = "0x0000000000000000000000000000000000000002"
    static let zero = "0x0000000000000000000000000000000000000000"
    static let allBalance = String(BigUInt(1) << 255)
    static let stableFlags: [String: String] = ["usdd202pool": "65792", "2pool": "131328", "2pooltusdusdt": "196864", "old3pool": "262400", "oldusdcpool": "69632", "usdc2pooltusdusdt": "135168", "usdd2pooltusdusdt": "200704", "usdj2pooltusdusdt": "266240"]

    public func quote(sender: String, input: Token?, output: Token?, amount: String, slippageBPS: UInt32 = 50, mode: TronDexMode = .smart) async throws -> TronDexQuote {
        _ = try TronNetwork.genesis(for: client.chain)
        guard TronAddress.validate(sender), (1...1000).contains(slippageBPS), input?.contract != output?.contract else { throw WalletError.invalid(L("message.invalid_tron_swap_network_assets_or_slippage")) }
        guard mode == .v2 || client.chain.id == TronAddress.chainID else { throw WalletError.invalid(L("tron.unsupported_test_route")) }
        for token in [input, output].compactMap({ $0 }) {
            guard token.chainID == client.chain.id, try await ContractABI.uint(client.read(TronInvocation(contract: token.contract, signature: "decimals()", arguments: []))) == BigUInt(token.decimals) else { throw WalletError.invalid(L("message.trc20_network_or_on_chain_decimals_mismatch")) }
        }
        let units = try Ethereum.parseUnits(amount, decimals: input?.decimals ?? 6)
        guard units > 0, units.bitWidth <= 128 else { throw WalletError.invalid(L("message.tron_swap_amount_out_of_range")) }
        let outputAmount: BigUInt, hops: [TronDexHop]
        if mode == .v2 {
            let deployment = try TronNetwork.v2Deployment(client.chain.id)
            let factory = try await readAddress(deployment.router, "factory()")
            guard factory == deployment.factory, try await readAddress(deployment.router, "WETH()") == deployment.wrapped else { throw WalletError.invalid(L("message.sunswap_v2_router_deployment_mismatch")) }
            let path = [input?.contract ?? deployment.wrapped, output?.contract ?? deployment.wrapped]
            guard path[0] != path[1] else { throw WalletError.invalid(L("message.this_flow_does_not_perform_standalone_trx_wrapping_unwrapping")) }
            let value = try await client.read(TronInvocation(contract: deployment.router, signature: "getAmountsOut(uint256,address[])", arguments: [String(units), ContractABI.json(path.map { try TronAddress.evm($0) })]))
            let amounts = try ContractABI.uintArray(value, count: 2)
            guard amounts[0] == units else { throw WalletError.invalid(L("message.sunswap_input_amount_mismatch")) }
            outputAmount = amounts[1]; hops = [.init(from: path[0], to: path[1], version: "v2", fee: 3000, parameters: nil)]
        } else {
            let candidate = try await smartQuote(input: input?.contract ?? Self.native, output: output?.contract ?? Self.native, units: units, slippage: slippageBPS)
            outputAmount = candidate.amount; hops = candidate.hops
            try await client.verifyCode(Self.universalRouter); try await client.verifyCode(Self.permit2)
            let manager = try await readAddress(Self.universalRouter, "clPoolManager()")
            guard manager == "TVjuTE3V5bMVdpfNhid8kD2v35T2k1u1Br" else { throw WalletError.invalid(L("message.sun_v4_poolmanager_does_not_match_the_pinned_deployment")) }
        }
        let minimum = outputAmount * BigUInt(10_000 - slippageBPS) / 10_000
        guard minimum > 0 else { throw WalletError.invalid(L("message.minimum_received_amount_must_be_greater_than_zero")) }
        let now = BigUInt(max(0, Int(Date().timeIntervalSince1970)))
        var deadline = now + 300
        if mode == .smart, let input {
            let values = try await permitValues(token: input.contract, sender: sender)
            if values.amount >= units, values.expiration >= now + 90 {
                deadline = min(deadline, values.expiration)
            }
        }
        let invocation = try Self.invocation(mode: mode, sender: sender, input: input, output: output, amount: units, minimum: minimum, deadline: deadline, hops: hops)
        return TronDexQuote(mode: mode, chainID: client.chain.id, sender: sender, input: input, output: output, amountIn: units, amountOut: outputAmount, minimumOut: minimum, slippageBPS: slippageBPS, deadline: deadline, quotedAt: Date(), hops: hops, invocation: invocation)
    }
    public func needsApproval(_ quote: TronDexQuote, sender: String) async throws -> Bool {
        try await approvalRequirement(quote, sender: sender) != .none
    }
    public func approvalRequirement(_ quote: TronDexQuote, sender: String) async throws -> DexApprovalRequirement {
        guard quote.chainID == client.chain.id, quote.sender == sender, !quote.isExpired else { throw WalletError.invalid(L("message.the_tron_approval_quote_or_account_changed")) }
        guard let token = quote.input else { return .none }
        let spender = quote.mode == .v2 ? try TronNetwork.v2Deployment(client.chain.id).router : Self.permit2
        let current = try await allowance(token: token.contract, owner: sender, spender: spender)
        if current < quote.amountIn { return current == 0 ? .token : .reset }
        if quote.mode == .smart, try await permitAllowance(quote, sender: sender) == false { return .permit2 }
        return .none
    }
    public func prepareApproval(_ quote: TronDexQuote, sender: String) async throws -> NativeTransferPlan {
        guard !quote.isExpired, quote.sender == sender, let token = quote.input else { throw WalletError.invalid(L("message.the_tron_approval_quote_expired_or_the_account_changed")) }
        let spender = quote.mode == .v2 ? try TronNetwork.v2Deployment(client.chain.id).router : Self.permit2
        let needed = try await approvalRequirement(quote, sender: sender)
        let invocation: TronInvocation
        switch needed {
        case .none: throw WalletError.invalid(L("message.the_current_allowance_is_sufficient_preview_the_swap_directly"))
        case .reset, .token:
            invocation = try TronInvocation(contract: token.contract, signature: "approve(address,uint256)", arguments: [TronAddress.evm(spender), needed == .reset ? "0" : String(quote.amountIn)])
        case .permit2:
            invocation = try TronInvocation(contract: Self.permit2, signature: "approve(address,address,uint160,uint48)", arguments: [TronAddress.evm(token.contract), TronAddress.evm(Self.universalRouter), String(quote.amountIn), String(quote.deadline)])
        }
        return try await client.prepare(sender: sender, invocation: invocation)
    }
    public func prepareSwap(_ quote: TronDexQuote, sender: String) async throws -> NativeTransferPlan {
        try await revalidate(quote, sender: sender)
        return try await client.prepare(sender: sender, invocation: quote.invocation, swap: quote)
    }
    func revalidate(_ quote: TronDexQuote, sender: String) async throws {
        guard quote.chainID == client.chain.id, quote.sender == sender, !quote.isExpired, quote.deadline > BigUInt(max(0, Int(Date().timeIntervalSince1970))) else { throw WalletError.invalid(L("message.the_tron_swap_quote_expired_or_the_account_changed")) }
        let rebuilt = try Self.invocation(mode: quote.mode, sender: sender, input: quote.input, output: quote.output, amount: quote.amountIn, minimum: quote.minimumOut, deadline: quote.deadline, hops: quote.hops)
        guard rebuilt == quote.invocation else { throw WalletError.invalid(L("message.tron_swap_recipient_path_or_limits_do_not_match")) }
        if let token = quote.input {
            guard try await client.balance(address: sender, token: token) >= quote.amountIn else { throw WalletError.invalid(L("message.insufficient_trc20_balance")) }
            guard try await needsApproval(quote, sender: sender) == false else { throw WalletError.invalid(L("message.approve_the_required_allowance_separately_wait_for_confirmation_then_get")) }
        }
    }
    private func allowance(token: String, owner: String, spender: String) async throws -> BigUInt {
        try ContractABI.uint(await client.read(TronInvocation(contract: token, signature: "allowance(address,address)", arguments: [TronAddress.evm(owner), TronAddress.evm(spender)])))
    }
    private func permitAllowance(_ quote: TronDexQuote, sender: String) async throws -> Bool {
        guard let token = quote.input else { return true }
        let values = try await permitValues(token: token.contract, sender: sender)
        return values.amount >= quote.amountIn && values.expiration >= quote.deadline
    }
    private func permitValues(token: String, sender: String) async throws -> (amount: BigUInt, expiration: BigUInt) {
        let result = try await client.read(TronInvocation(contract: Self.permit2, signature: "allowance(address,address,address)", arguments: [TronAddress.evm(sender), TronAddress.evm(token), TronAddress.evm(Self.universalRouter)]))
        let values = try ContractABI.uintWords(result, count: 3)
        guard values[0].bitWidth <= 160, values[1].bitWidth <= 48, values[2].bitWidth <= 48 else { throw WalletError.invalid(L("message.permit2_returned_an_invalid_allowance")) }
        return (values[0], values[1])
    }
    private func readAddress(_ contract: String, _ signature: String) async throws -> String {
        try TronAddress.base58(ContractABI.address(await client.read(TronInvocation(contract: contract, signature: signature, arguments: []))))
    }
    private func smartQuote(input: String, output: String, units: BigUInt, slippage: UInt32) async throws -> (amount: BigUInt, hops: [TronDexHop]) {
        var url = URLComponents(string: "https://open.sun.io/apiv2/quote/swap/routerUniversal")!
        // Quote service learns only pair/amount. No sender, wallet ID or identity headers.
        url.queryItems = [URLQueryItem(name: "fromToken", value: input), URLQueryItem(name: "toToken", value: output), URLQueryItem(name: "amountIn", value: String(units)), URLQueryItem(name: "maxCost", value: "3"), URLQueryItem(name: "includeUnverifiedV4Hook", value: "false"), URLQueryItem(name: "slippageBips", value: String(slippage))]
        let data = try await client.native.transport.execute(PrivateRequest(url: url.url!, isolation: client.native.isolation))
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        guard result["code"] == .number(0), case .array(let rows) = result["data"], !rows.isEmpty, rows.count <= 3 else { throw WalletError.invalid(L("message.the_official_sun_routing_service_returned_no_valid_path")) }
        for row in rows {
            if let parsed = try? Self.parseRoute(row, input: input, output: output, amount: units) { return parsed }
        }
        throw WalletError.invalid(L("message.the_quote_contains_only_unsupported_paths_unknown_hooks_or_inconsistent"))
    }
    static func parseRoute(_ row: JSONValue, input: String, output: String, amount: BigUInt) throws -> (amount: BigUInt, hops: [TronDexHop]) {
        guard row["containsUnverifiedHook"] == .bool(false), row["amountInRaw"]?.string == String(amount), let out = row["amountOutRaw"]?.string, let units = BigUInt(out), units > 0, units.bitWidth <= 128,
              case .array(let tokens) = row["tokens"], (2...5).contains(tokens.count), tokens.first == .string(input), tokens.last == .string(output),
              case .array(let versions) = row["poolVersions"], versions.count == tokens.count - 1,
              case .array(let fees) = row["poolFees"], fees.count == tokens.count,
              case .array(let keys) = row["poolKeys"], keys.count == versions.count else { throw WalletError.invalid(L("message.sun_quote_amount_or_path_mismatch")) }
        for field in ["amountInRawReferral", "amountOutRawReferral"] { if let value = row[field] { guard value == .string("0") else { throw WalletError.invalid(L("message.routes_with_referral_fees_are_not_accepted")) } } }
        var hops: [TronDexHop] = []
        for i in versions.indices {
            guard let from = tokens[i].string, let to = tokens[i + 1].string, TronAddress.validate(from), TronAddress.validate(to), from != to,
                  let rawVersion = versions[i].string, ["v1", "v2", "v3", "v4", "wtrx", "usdt20psm"].contains(rawVersion) || Self.stableFlags[rawVersion] != nil else { throw WalletError.invalid(L("message.unknown_sun_routing_protocol")) }
            // SUN's API may label the native/WTRX identity hop with a pool version.
            // Its official SDK recognizes this pair as wrapping before protocol dispatch.
            let version = Set([from, to]) == Set([Self.native, Self.wrapped]) ? "wtrx" : rawVersion
            let fee = fees[i].string.flatMap(UInt32.init) ?? 0
            guard fee < 1_000_000 else { throw WalletError.invalid(L("message.invalid_sun_fee")) }
            if version == "v3" || version == "v4" { guard fee > 0 else { throw WalletError.invalid(L("message.missing_sun_pool_fee")) } }
            var parameters: String?
            if version == "v4" {
                let key = keys[i]
                guard key["hooks"] == .string(Self.native), let token0 = key["token0"]?.string, let token1 = key["token1"]?.string,
                      Set([token0, token1]) == Set([from, to]), let encoded = key["parameters"]?.string, let bytes = try? Data(strictHex: encoded), bytes.count == 32,
                      BigUInt(bytes) & 65535 == 0, BigUInt(bytes) >> 40 == 0, BigUInt(bytes) >> 16 > 0, BigUInt(bytes) >> 16 < 8_388_608 else { throw WalletError.invalid(L("message.v4_accepts_only_standard_concentrated_liquidity_pools_without_hooks")) }
                let keyFee: BigUInt
                switch key["fee"] { case .number(let n) where n >= 0: keyFee = BigUInt(n); case .string(let n): guard let value = BigUInt(n) else { throw WalletError.invalid("V4 fee") }; keyFee = value; default: throw WalletError.invalid("V4 fee") }
                guard keyFee == BigUInt(fee) else { throw WalletError.invalid(L("message.v4_pool_key_fee_mismatch")) }; parameters = encoded
            }
            if version == "wtrx" { guard Set([from, to]) == Set([Self.native, Self.wrapped]) else { throw WalletError.invalid(L("message.invalid_wtrx_wrapping_path")) } }
            if version == "v2" || version == "v3" { guard from != Self.native, to != Self.native else { throw WalletError.invalid(L("message.v2_v3_require_an_explicit_wtrx_path")) } }
            hops.append(.init(from: from, to: to, version: version, fee: fee, parameters: parameters))
        }
        return (units, hops)
    }
    static func invocation(mode: TronDexMode, sender: String, input: Token?, output: Token?, amount: BigUInt, minimum: BigUInt, deadline: BigUInt, hops: [TronDexHop]) throws -> TronInvocation {
        if mode == .v2 {
            let deployment = try TronNetwork.v2Deployment(input?.chainID ?? output?.chainID ?? TronAddress.chainID)
            let path = try ContractABI.json([input?.contract ?? deployment.wrapped, output?.contract ?? deployment.wrapped].map { try TronAddress.evm($0) })
            if input == nil { return try TronInvocation(contract: deployment.router, signature: "swapExactETHForTokens(uint256,address[],address,uint256)", arguments: [String(minimum), path, TronAddress.evm(sender), String(deadline)], callValue: amount) }
            return try TronInvocation(contract: deployment.router, signature: output == nil ? "swapExactTokensForETH(uint256,uint256,address[],address,uint256)" : "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)", arguments: [String(amount), String(minimum), path, TronAddress.evm(sender), String(deadline)])
        }
        var commands = Data(), inputs: [String] = []
        func append(_ command: UInt8, _ types: [String], _ values: [String]) throws { commands.append(command); inputs.append("0x" + (try ContractABI.parameters(types: types, arguments: values)).hexString) }
        if let input { try append(0x02, ["address", "address", "uint160"], [TronAddress.evm(input.contract), Self.thisAddress, String(amount)]) }
        for (index, hop) in hops.enumerated() {
            let from = try TronAddress.evm(hop.from), to = try TronAddress.evm(hop.to), units = index == 0 ? String(amount) : Self.allBalance
            if hop.version == "wtrx" { try append(hop.from == Self.native ? 0x0b : 0x0c, ["address", "uint256"], [Self.thisAddress, hop.from == Self.native ? units : "0"]); continue }
            if hop.version == "v4" {
                guard let parameters = hop.parameters else { throw WalletError.invalid(L("message.missing_v4_pool_key")) }
                let ordered = [from, to].sorted { $0.lowercased() < $1.lowercased() }
                let key = try ContractABI.json([ordered[0], ordered[1], Self.zero, String(hop.fee), parameters])
                let swap = try ContractABI.json([key, from.lowercased() == ordered[0].lowercased() ? "true" : "false", "0", "0", "0x"])
                let plans = [try ContractABI.parameters(types: ["address", "uint256", "bool"], arguments: [from, units, "false"]), try ContractABI.parameters(types: ["((address,address,address,uint24,bytes32),bool,uint128,uint128,bytes)"], arguments: [swap]), try ContractABI.parameters(types: ["address", "address", "uint256"], arguments: [to, Self.thisAddress, "0"]), try ContractABI.parameters(types: ["address", "address", "uint256"], arguments: [from, Self.thisAddress, "0"])]
                try append(0x12, ["bytes", "bytes[]"], ["0x0b060e0e", ContractABI.json(plans.map { "0x" + $0.hexString })]); continue
            }
            if hop.version == "v3" {
                let packed = try Data(strictHex: from) + Data([UInt8((hop.fee >> 16) & 255), UInt8((hop.fee >> 8) & 255), UInt8(hop.fee & 255)]) + Data(strictHex: to)
                try append(0x00, ["address", "uint256", "uint256", "bytes", "bool"], [Self.thisAddress, units, "0", "0x" + packed.hexString, "false"]); continue
            }
            var types = ["address", "uint256", "uint256", "address[]"], values = [Self.thisAddress, units, "0", try ContractABI.json([from, to])]
            let command: UInt8
            if hop.version == "v2" { command = 0x08 }
            else if hop.version == "v1" { command = 0x10 }
            else if hop.version == "usdt20psm" { command = 0x24; types.append("uint256[]"); values.append(try ContractABI.json(["65552"])) }
            else if let flag = Self.stableFlags[hop.version] { command = 0x22; types.append("uint256[]"); values.append(try ContractABI.json([flag])) }
            else { throw WalletError.invalid(L("message.unknown_sun_routing_command")) }
            types.append("bool"); values.append("false"); try append(command, types, values)
        }
        let receiver = try TronAddress.evm(sender), out = try TronAddress.evm(output?.contract ?? Self.native)
        // Final output sweep is the single aggregate min-fill check. No partial-failure flags,
        // arbitrary target calls, referral fees or externally supplied command bytes.
        try append(0x04, ["address", "address", "uint160"], [out, receiver, String(minimum)])
        for token in Set(hops.flatMap { [$0.from, $0.to] }).sorted() {
            let address = try TronAddress.evm(token); if address.lowercased() != out.lowercased() { try append(0x04, ["address", "address", "uint160"], [address, receiver, "0"]) }
        }
        return try TronInvocation(contract: Self.universalRouter, signature: "execute(bytes,bytes[],uint256)", arguments: ["0x" + commands.hexString, ContractABI.json(inputs), String(deadline)], callValue: input == nil ? amount : 0)
    }
}
