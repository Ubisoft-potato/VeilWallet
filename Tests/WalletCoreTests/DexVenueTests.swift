import Foundation
import Testing
import BigInt
@testable import WalletCore

private let coinA = "0x1111111111111111111111111111111111111111"
private let coinB = "0x2222222222222222222222222222222222222222"
private let wrappedCoin = "0x3333333333333333333333333333333333333333"
private let poolCoin = "0x4444444444444444444444444444444444444444"
private let testSender = "0x000000000000000000000000000000000000dEaD"
private struct VenueMock: PrivateRequesting {
    let venue: DexVenue
    var scenario = ""
    var decimals = 6
    var permitExpiry: BigUInt?
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
        guard let method = body["method"]?.string, case .array(let params) = body["params"] else { throw WalletError.invalid("test request") }
        let result: JSONValue
        let unit = BigUInt(10).power(decimals)
        func word(_ n: BigUInt) -> JSONValue { .string("0x" + ContractABI.word(n).hexString) }
        func address(_ s: String) throws -> JSONValue { word(BigUInt(try Data(strictHex: s))) }
        func array(_ values: [BigUInt]) -> JSONValue { .string("0x" + (ContractABI.word(32) + ContractABI.word(BigUInt(values.count)) + values.reduce(Data()) { $0 + ContractABI.word($1) }).hexString) }
        func sel(_ s: String) -> String { "0x" + Data(Data(s.utf8).keccak256.prefix(4)).hexString }
        switch method {
        case "eth_chainId": result = .string(Ethereum.quantity(BigUInt(venue.chainID)))
        case "eth_getCode": result = .string(scenario == "noCode" ? "0x" : (venue.protocol == .balancerV3 ? "0x6000" + (scenario == "wrongFactory" ? coinA : venue.factory!).dropFirst(2) : "0x6000"))
        case "eth_getTransactionCount": result = .string("0x0")
        case "eth_getBlockByNumber": result = .object(["baseFeePerGas": .string("0x1"), "timestamp": .string(Ethereum.quantity(BigUInt(Int(Date().timeIntervalSince1970))))])
        case "eth_maxPriorityFeePerGas": result = .string("0x1")
        case "eth_gasPrice": result = .string("0x2")
        case "eth_estimateGas": result = .string("0x30d40")
        case "eth_getBalance": result = .string("0x56bc75e2d63100000")
        case "eth_call":
            guard let data = params[0]["data"]?.string else { throw WalletError.invalid("test calldata") }
            let selector = String(data.prefix(10))
            switch selector {
            case sel("factory()"), sel("defaultFactory()"), sel("getFactory()"), sel("poolManager()"), sel("getVault()"):
                result = try address(scenario == "wrongFactory" ? coinA : venue.factory!)
            case sel("WETH()"), sel("WETH9()"), sel("WNativeToken()"), sel("weth()"), sel("WAVAX()"), sel("getWNATIVE()"), sel("getWeth()"):
                result = try address(venue.wrapped ?? wrappedCoin)
            case sel("getPermit2()"): result = try address(EVMVenueClient.permit2)
            case sel("decimals()"): result = word(BigUInt(decimals))
            case sel("balanceOf(address)"): result = word(9 * unit)
            case sel("allowance(address,address)"):
                result = word(scenario == "emptyAllowance" ? 0 : (scenario == "nonzeroAllowance" ? 1 : unit))
            case sel("allowance(address,address,address)"):
                result = .string("0x" + (ContractABI.word(scenario == "missingPermit" ? 0 : unit) + ContractABI.word(scenario == "expiredPermit" ? 0 : (permitExpiry ?? BigUInt(Int(Date().timeIntervalSince1970) + 600))) + ContractABI.word(0)).hexString)
            case sel("getAmountsOut(uint256,address[])"), sel("getAmountsOut(uint256,(address,address,bool,address)[])"):
                result = array([unit, 2 * unit])
            case sel("quoteExactInput(bytes,uint256)"), sel("get_dy(int128,int128,uint256)"), sel("querySwapSingleTokenExactIn(address,address,address,uint256,address,bytes)"): result = word(2 * unit)
            case sel("quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))"):
                result = .string("0x" + (ContractABI.word(2 * unit) + ContractABI.word(100_000)).hexString)
            case sel("getLBPairInformation(address,address,uint256)"):
                result = .string("0x" + (ContractABI.word(20) + ContractABI.word(BigUInt(try Data(strictHex: poolCoin))) + ContractABI.word(0) + ContractABI.word(0)).hexString)
            case sel("getTokenX()"): result = try address(coinA)
            case sel("getSwapOut(address,uint128,bool)"):
                result = .string("0x" + (ContractABI.word(scenario == "partialLB" ? 1 : 0) + ContractABI.word(2 * unit) + ContractABI.word(3000)).hexString)
            case sel("coins(uint256)"):
                let index = BigUInt(try Data(strictHex: String(data.dropFirst(10))))
                result = try address(index == 0 ? coinA : (index == 1 ? coinB : wrappedCoin))
            case sel("isPoolRegistered(address)"), sel("isPoolInitialized(address)"): result = word(scenario == "unregistered" ? 0 : 1)
            case sel("isPoolPaused(address)"): result = word(scenario == "paused" ? 1 : 0)
            case sel("getPoolTokens(address)"):
                result = .string("0x" + (try ContractABI.parameters(types: ["address[]"], arguments: [ContractABI.json([coinA, coinB, wrappedCoin])])).hexString)
            default: result = word(1) // successful fixed local write simulation only
            }
        default: throw WalletError.invalid("Unexpected EVM venue test method")
        }
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result]))
    }
}

struct DexVenueTests {
    @Test func requoteUsesRemainingPermit2LifetimeWithoutAnApprovalLoop() async throws {
        let venue = DexCatalog.find("uniswap-v4-1")!, chain = Chain.defaults.first { $0.id == 1 }!
        let input = try Token(chainID: 1, contract: coinA, symbol: "IN", decimals: 6), output = try Token(chainID: 1, contract: coinB, symbol: "OUT", decimals: 6)
        let expiry = BigUInt(Int(Date().timeIntervalSince1970) + 180)
        let dex = DexClient(rpc: RPCClient(transport: VenueMock(venue: venue, permitExpiry: expiry), chain: chain, isolation: "test"))
        let fresh = try await dex.quote(sender: testSender, input: input, output: output, amount: "1", venueID: venue.id)
        #expect(fresh.deadline == expiry)
        #expect(try await dex.approvalRequirement(fresh, sender: testSender) == .none)
        #expect(try await dex.prepareSwap(fresh, sender: testSender).purpose.isSwap)
        let almostExpired = DexClient(rpc: RPCClient(transport: VenueMock(venue: venue, permitExpiry: BigUInt(Int(Date().timeIntervalSince1970) + 30)), chain: chain, isolation: "test"))
        let short = try await almostExpired.quote(sender: testSender, input: input, output: output, amount: "1", venueID: venue.id)
        #expect(try await almostExpired.approvalRequirement(short, sender: testSender) == .permit2)
    }
    @Test(arguments: ["pancake-v2-56", "pancake-v3-56"])
    func bscUSDTApprovalResumesWithFreshSwapInsteadOfAnotherApproval(id: String) async throws {
        let venue = try #require(DexCatalog.find(id)), chain = Chain.defaults.first { $0.id == 56 }!
        let input = try #require(TokenCatalog.all.first { $0.chainID == 56 && $0.symbol == "USDT" }).token
        let output = try #require(TokenCatalog.all.first { $0.chainID == 56 && $0.symbol == "USDC" }).token
        #expect(input.decimals == 18); #expect(output.decimals == 18)
        func client(_ scenario: String) -> DexClient { DexClient(rpc: RPCClient(transport: VenueMock(venue: venue, scenario: scenario, decimals: 18), chain: chain, isolation: "test")) }
        let before = client("emptyAllowance")
        let quote = try await before.quote(sender: testSender, input: input, output: output, amount: "1", venueID: id)
        #expect(try await before.approvalRequirement(quote, sender: testSender) == .token)
        let approval = try await before.prepareApproval(quote, sender: testSender)
        #expect(approval.purpose.invocation?.signature == "approve(address,uint256)")
        #expect(approval.purpose.invocation?.arguments.last == "1000000000000000000")
        #expect(!approval.purpose.isSwap); #expect(approval.transaction.to.lowercased() == input.contract.lowercased())
        #expect(quote.matchesApproval(try #require(approval.purpose.invocation)))
        do { _ = try await before.prepareSwap(quote, sender: testSender); Issue.record("BSC swap skipped approval") } catch {}
        let reset = client("nonzeroAllowance")
        #expect(try await reset.approvalRequirement(quote, sender: testSender) == .reset)
        #expect(try await reset.prepareApproval(quote, sender: testSender).purpose.invocation?.arguments.last == "0")
        let after = client("")
        let fresh = try await after.quote(sender: testSender, input: input, output: output, amount: "1", venueID: id)
        #expect(fresh.quotedAt >= quote.quotedAt)
        #expect(try await after.approvalRequirement(fresh, sender: testSender) == .none)
        let swap = try await after.prepareSwap(fresh, sender: testSender)
        #expect(swap.purpose.isSwap); #expect(swap.transaction.to.lowercased() == venue.router.lowercased())
        #expect(swap.transaction.data == fresh.invocation.data); #expect(!fresh.matchesApproval(fresh.invocation))
        do { _ = try await after.prepareApproval(fresh, sender: testSender); Issue.record("BSC sufficient allowance produced a duplicate approval") } catch {}
        let expired = DexQuote(chainID: fresh.chainID, input: fresh.input, output: fresh.output, amountIn: fresh.amountIn, amountOut: fresh.amountOut, minimumOut: fresh.minimumOut, slippageBPS: fresh.slippageBPS, path: fresh.path, deadline: fresh.deadline, quotedAt: Date().addingTimeInterval(-91), invocation: fresh.invocation, venueID: fresh.venueID, fee: fresh.fee)
        do { _ = try await after.prepareSwap(expired, sender: testSender); Issue.record("Expired pre-approval quote was reused") } catch {}
    }
    @Test(arguments: DexCatalog.all.map(\.id))
    func everyDeploymentCanCompleteApprovalThenPrepareTheSwap(id: String) async throws {
        let venue = try #require(DexCatalog.find(id)), chain = try #require(Chain.defaults.first { $0.id == venue.chainID })
        for decimals in [6, 18] {
            let input = try Token(chainID: chain.id, contract: coinA, symbol: "IN", decimals: decimals)
            let output = try Token(chainID: chain.id, contract: coinB, symbol: "OUT", decimals: decimals)
            let unit = BigUInt(10).power(decimals)
            func dex(_ scenario: String) -> DexClient { .init(rpc: .init(transport: VenueMock(venue: venue, scenario: scenario, decimals: decimals), chain: chain, isolation: "fixture")) }
            let fee: UInt32 = venue.protocol == .liquidityBook ? 20 : (venue.protocol == .slipstream ? 100 : 3000)
            func quote(_ client: DexClient) async throws -> DexQuote {
                try await client.quote(sender: testSender, input: input, output: output, amount: "1", venueID: id, fee: fee, poolID: venue.usesPoolID ? poolCoin : nil)
            }
            let empty = dex("emptyAllowance"), pending = try await quote(empty)
            #expect(try await empty.approvalRequirement(pending, sender: testSender) == .token)
            let approval = try await empty.prepareApproval(pending, sender: testSender)
            #expect(pending.matchesApproval(try #require(approval.purpose.invocation)))
            #expect(approval.purpose.invocation?.arguments.last == String(unit))
            #expect(!approval.purpose.isSwap)
            let reset = dex("nonzeroAllowance")
            #expect(try await reset.approvalRequirement(pending, sender: testSender) == .reset)
            #expect(try await reset.prepareApproval(pending, sender: testSender).purpose.invocation?.arguments.last == "0")
            if venue.usesPermit2 {
                let permit = dex("missingPermit"), fresh = try await quote(permit)
                #expect(try await permit.approvalRequirement(fresh, sender: testSender) == .permit2)
                let preview = try await permit.prepareApproval(fresh, sender: testSender)
                #expect(fresh.matchesApproval(try #require(preview.purpose.invocation)))
                #expect(preview.purpose.invocation?.arguments[2] == String(unit))
            }
            let ready = dex(""), fresh = try await quote(ready)
            #expect(try await ready.approvalRequirement(fresh, sender: testSender) == .none)
            let swap = try await ready.prepareSwap(fresh, sender: testSender)
            #expect(swap.purpose.isSwap); #expect(swap.transaction.data == fresh.invocation.data)
            #expect(swap.transaction.to.lowercased() == venue.router.lowercased())
            do { _ = try await ready.prepareApproval(fresh, sender: testSender); Issue.record("Duplicate approval after confirmed allowance") } catch {}
        }
    }
    @Test func catalogIsUniqueAndUsesCanonicalPinnedSources() throws {
        #expect(DexCatalog.all.count >= 79); #expect(Set(DexCatalog.all.map(\.id)).count == DexCatalog.all.count)
        for venue in DexCatalog.all {
            #expect(Ethereum.validateAddress(venue.router)); #expect(venue.source.hasPrefix("https://"))
            if let address = venue.factory { #expect(Ethereum.validateAddress(address)) }
            if let address = venue.quoter { #expect(Ethereum.validateAddress(address)) }
        }
    }
    @Test(arguments: DexCatalog.all.map(\.id))
    func allProtocolFamiliesQuoteAndRevalidatePinnedIntent(id: String) async throws {
        let venue = try #require(DexCatalog.find(id)), chain = try #require(Chain.defaults.first { $0.id == venue.chainID })
        let rpc = RPCClient(transport: VenueMock(venue: venue), chain: chain, isolation: "test"), dex = DexClient(rpc: rpc)
        let input = try Token(chainID: chain.id, contract: coinA, symbol: "IN", decimals: 6), output = try Token(chainID: chain.id, contract: coinB, symbol: "OUT", decimals: 6)
        let fee: UInt32 = venue.protocol == .liquidityBook ? 20 : (venue.protocol == .slipstream ? 100 : 3000)
        let quote = try await dex.quote(sender: testSender, input: input, output: output, amount: "1", venueID: id, fee: fee, stable: venue.protocol == .solidly, poolID: venue.protocol == .balancerV3 ? poolCoin : nil)
        #expect(quote.amountIn == 1_000_000); #expect(quote.minimumOut == 1_990_000); #expect(quote.invocation.nativeValue == 0)
        #expect(quote.invocation.contract.lowercased() == venue.router.lowercased()); #expect(quote.venueName == venue.name)
        try await EVMVenueClient(rpc: rpc).revalidate(quote, sender: testSender)
        let fixedPool = [.curve, .curveETH].contains(venue.protocol)
        let wrong = RPCClient(transport: VenueMock(venue: venue, scenario: fixedPool ? "noCode" : "wrongFactory"), chain: chain, isolation: "test")
        if venue.factory != nil || fixedPool {
            do { try await EVMVenueClient(rpc: wrong).revalidate(quote, sender: testSender); Issue.record("DEX foreign deployment accepted") } catch {}
        }
    }
    @Test func permit2RequiresSeparateExactAndShortLivedOnchainApproval() async throws {
        let venue = try #require(DexCatalog.find("uniswap-v4-1")), chain = Chain.defaults.first { $0.id == 1 }!
        let input = try Token(chainID: 1, contract: coinA, symbol: "IN", decimals: 6), output = try Token(chainID: 1, contract: coinB, symbol: "OUT", decimals: 6)
        for scenario in ["emptyAllowance", "nonzeroAllowance", "missingPermit", "expiredPermit"] {
            let dex = DexClient(rpc: RPCClient(transport: VenueMock(venue: venue, scenario: scenario), chain: chain, isolation: "test"))
            let quote = try await dex.quote(sender: testSender, input: input, output: output, amount: "1", venueID: venue.id)
            #expect(try await dex.needsApproval(quote, sender: testSender))
            #expect(try await dex.approvalRequirement(quote, sender: testSender) == (scenario == "emptyAllowance" ? .token : (scenario == "nonzeroAllowance" ? .reset : .permit2)))
            let approval = try await dex.prepareApproval(quote, sender: testSender)
            let call = try #require(approval.purpose.invocation)
            #expect(quote.matchesApproval(call))
            if scenario == "emptyAllowance" || scenario == "nonzeroAllowance" {
                #expect(call.signature == "approve(address,uint256)"); #expect(call.arguments[0].lowercased() == EVMVenueClient.permit2)
                #expect(call.arguments[1] == (scenario == "emptyAllowance" ? "1000000" : "0"))
            } else {
                #expect(call.signature == "approve(address,address,uint160,uint48)"); #expect(call.arguments[2] == "1000000")
                #expect(BigUInt(call.arguments[3]) == quote.deadline)
            }
            do { _ = try await dex.prepareSwap(quote, sender: testSender); Issue.record("Swap skipped required approval") } catch {}
        }
    }
    @Test func nativeV3AndRouter02UnwrapAndRefundAreExplicit() throws {
        for id in ["uniswap-v3-1", "uniswap-v3-8453", "quick-algebra-137"] {
            let venue = try #require(DexCatalog.find(id)), chain = Chain.defaults.first { $0.id == venue.chainID }!
            let client = EVMVenueClient(rpc: RPCClient(transport: VenueMock(venue: venue), chain: chain, isolation: "test"))
            let token = try Token(chainID: chain.id, contract: coinB, symbol: "OUT", decimals: 6)
            let call = try client.invocation(venue: venue, sender: testSender, input: nil, output: token, path: [wrappedCoin, coinB], amount: 1_000_000, minimum: 100, deadline: 1_900_000_000, fee: 3000, stable: false)
            #expect(call.nativeValue == 1_000_000); #expect(call.signature.contains("multicall"))
            let output = try client.invocation(venue: venue, sender: testSender, input: token, output: nil, path: [coinB, wrappedCoin], amount: 1_000_000, minimum: 100, deadline: 1_900_000_000, fee: 3000, stable: false)
            #expect(output.nativeValue == 0); #expect(output.signature.contains("multicall"))
        }
    }
    @Test func feeSelectionComparesSuccessfulQuotesAndRejectsAnEmptySet() async throws {
        let venue = DexCatalog.find("pancake-v3-56")!, chain = Chain.defaults.first { $0.id == 56 }!
        let client = EVMVenueClient(rpc: RPCClient(transport: VenueMock(venue: venue), chain: chain, isolation: "test"))
        let best = try await client.bestFee([100, 500, 2500, 10000]) { fee in
            if fee == 100 { throw WalletError.invalid("No pool") }
            return fee == 2500 ? 200 : (fee == 10000 ? 0 : 100)
        }
        #expect(best.fee == 2500); #expect(best.amount == 200)
        let tie = try await client.bestFee([500, 100]) { _ in 200 }
        #expect(tie.fee == 100)
        do { _ = try await client.bestFee([500]) { _ in throw WalletError.invalid("No pool") }; Issue.record("Unavailable pool became a quote") } catch {}
    }
    @Test func nativeV4InputAlwaysRefundsUnsettledValueToReviewedSender() throws {
        let venue = DexCatalog.find("uniswap-v4-1")!, chain = Chain.defaults.first { $0.id == 1 }!
        let client = EVMVenueClient(rpc: RPCClient(transport: VenueMock(venue: venue), chain: chain, isolation: "test"))
        let token = try Token(chainID: 1, contract: coinB, symbol: "OUT", decimals: 6)
        let call = try client.invocation(venue: venue, sender: testSender, input: nil, output: token, path: [EVMVenueClient.zero, coinB], amount: 1000, minimum: 900, deadline: 1_900_000_000, fee: 3000, stable: false)
        #expect(call.nativeValue == 1000); #expect(call.arguments[0] == "0x1004")
        let inputs = try JSONDecoder().decode([String].self, from: Data(call.arguments[1].utf8))
        #expect(inputs.count == 2)
        let refund = try Data(strictHex: inputs[1])
        let receiver = BigUInt(try Data(strictHex: testSender))
        #expect(refund == ContractABI.word(0) + ContractABI.word(receiver) + ContractABI.word(0))
    }
    @Test(arguments: ["partialLB", "unregistered", "paused"])
    func partialLBAndUnregisteredBalancerPoolsCannotProduceSwapQuotes(scenario: String) async throws {
        let venue = DexCatalog.find(scenario == "partialLB" ? "lfj-lb-43114" : "balancer-v3-1")!, chain = Chain.defaults.first { $0.id == venue.chainID }!
        let dex = DexClient(rpc: RPCClient(transport: VenueMock(venue: venue, scenario: scenario), chain: chain, isolation: "test"))
        let input = try Token(chainID: chain.id, contract: coinA, symbol: "IN", decimals: 6), output = try Token(chainID: chain.id, contract: coinB, symbol: "OUT", decimals: 6)
        do { _ = try await dex.quote(sender: testSender, input: input, output: output, amount: "1", venueID: venue.id, fee: 20, poolID: poolCoin); Issue.record("Invalid pool quote accepted") } catch {}
    }
}
