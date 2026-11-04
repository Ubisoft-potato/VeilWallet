import Foundation
import Testing
import BigInt
@testable import WalletCore

private let testUSDT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
private let tronGenesis = "00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc"
private struct TronMock: PrivateRequesting {
    let scenario: String
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try request.body.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        let response: JSONValue
        func word(_ n: BigUInt) -> String { ContractABI.word(n).hexString }
        switch request.url.path {
        case "/wallet/getblockbynum": response = .object(["blockID": .string(scenario == "wrongChain" ? String(repeating: "0", count: 64) : tronGenesis)])
        case "/wallet/getcontract": response = .object(["bytecode": .string(scenario == "noCode" ? "" : "6000")])
        case "/wallet/getaccount":
            let address = body?["address"] ?? .null
            var info: [String: JSONValue] = ["address": address, "balance": .unsigned(9_000_000_000)]
            if scenario == "ownerChanged" { info["owner_permission"] = .object(["threshold": .number(1), "keys": .array([.object(["address": address, "weight": .number(1)]), .object(["address": address, "weight": .number(1)])])]) }
            response = .object(info)
        case "/wallet/getnowblock": response = .object(["blockID": .string(String(repeating: "0", count: 64)), "block_header": .object(["raw_data": .object(["timestamp": .unsigned(UInt64(Date().timeIntervalSince1970 * 1000))])])])
        case "/wallet/getchainparameters": response = .object(["chainParameter": .array([.object(["key": .string("getEnergyFee"), "value": .number(420)]), .object(["key": .string("getTransactionFee"), "value": .number(1000)]), .object(["key": .string("getMaxFeeLimit"), "value": .unsigned(15_000_000_000)])])])
        case "/wallet/triggerconstantcontract":
            guard let encoded = body?["data"]?.string else { throw WalletError.invalid("test missing calldata") }
            let selector = String(encoded.prefix(8)); func sel(_ s: String) -> String { Data(Data(s.utf8).keccak256.prefix(4)).hexString }
            let result: String
            switch selector {
            case sel("factory()"): result = try ContractABI.word(BigUInt(Data(strictHex: TronAddress.evm(TronDexClient.v2Factory)))).hexString
            case sel("WETH()"): result = try ContractABI.word(BigUInt(Data(strictHex: TronAddress.evm(TronDexClient.wrapped)))).hexString
            case sel("decimals()"): result = word(6)
            case sel("getAmountsOut(uint256,address[])"): result = word(32) + word(2) + word(1_000_000) + word(300_000)
            case sel("allowance(address,address)"): result = word(scenario == "approved" ? 1_000_000 : 0)
            case sel("approve(address,uint256)"): result = word(scenario == "falseApprove" ? 0 : 1)
            default: result = ""
            }
            let outcome: JSONValue = scenario == "vmFailure" ? .object(["ret": .string("FAILED")]) : scenario == "contractFailure" ? .object(["contractRet": .string("REVERT")]) : .object([:])
            response = .object(["result": .object(["result": .bool(scenario != "revert")]), "constant_result": .array([.string(result)]), "energy_used": .number(scenario == "energyChanged" ? 100_000 : 1000), "transaction": .object(["ret": .array([outcome])])])
        default: throw WalletError.invalid("Unexpected TRON mock path")
        }
        return try JSONEncoder().encode(response)
    }
}

struct TronDexTests {
    private func client(_ scenario: String = "") -> TronContractClient { .init(transport: TronMock(scenario: scenario), chain: NetworkCatalog.nativeChains.first { $0.family == .tron }!, isolation: "test") }
    private func account() throws -> WalletAccount { try MultichainCrypto.importPrivateKey(String(repeating: "01", count: 32), profile: AccountProfile.find("tron")!) }
    @Test func previousTronDefaultMigratesWhileCustomRPCIsPreserved() throws {
        var chain = NetworkCatalog.nativeChains.first { $0.family == .tron }!
        chain.rpcURL = "https://api.trongrid.io"
        #expect(NetworkCatalog.mergeDefaults(into: [chain]).first?.rpcURL == "https://api.tronstack.io")
        chain.rpcURL = "https://custom.example.com"
        #expect(NetworkCatalog.mergeDefaults(into: [chain]).first?.rpcURL == chain.rpcURL)
    }
    @Test func base58TVMConversionAndTokenIdentityAreStrict() throws {
        let evm = try TronAddress.evm(testUSDT)
        #expect(evm.count == 42); #expect(try TronAddress.base58(evm) == testUSDT)
        let token = try Token(chainID: TronAddress.chainID, contract: testUSDT, symbol: "USDT", decimals: 6)
        #expect(token.id.hasSuffix(testUSDT)); #expect(token.contract == testUSDT)
        do { _ = try Token(chainID: TronAddress.chainID, contract: testUSDT.lowercased(), symbol: "USDT", decimals: 6); Issue.record("TRON address case discarded") } catch {}
    }
    @Test func nativeTRXSwapPreviewsEnergyAndRevalidatesBeforeSigning() async throws {
        let account = try account(), dex = TronDexClient(client: client())
        let token = try Token(chainID: TronAddress.chainID, contract: testUSDT, symbol: "USDT", decimals: 6)
        let quote = try await dex.quote(sender: account.address, input: nil, output: token, amount: "1", mode: .v2)
        #expect(quote.amountIn == 1_000_000); #expect(quote.minimumOut == 298_500)
        #expect(quote.invocation.signature == "swapExactETHForTokens(uint256,address[],address,uint256)")
        let plan = try await dex.prepareSwap(quote, sender: account.address)
        #expect(plan.contract?.callValue == 1_000_000); #expect(plan.payload.contractData != nil); #expect(BigUInt(plan.payload.feeLimit!) == 630_000)
        #expect(plan.feeBudget > 630_000)
        try await NativeTransferClient(transport: TronMock(scenario: ""), chain: client().chain, isolation: "test").revalidate(plan, account: account)
        for failure in ["energyChanged", "ownerChanged", "wrongChain", "revert", "noCode", "vmFailure", "contractFailure"] {
            do { try await client(failure).revalidate(plan); Issue.record("Changed TRON execution accepted") } catch {}
        }
    }
    @Test func approvalIsLocalZeroValueContractAndFalseReturnBlocks() async throws {
        let account = try account(), dex = TronDexClient(client: client())
        let token = try Token(chainID: TronAddress.chainID, contract: testUSDT, symbol: "USDT", decimals: 6)
        let quote = try await dex.quote(sender: account.address, input: token, output: nil, amount: "1", mode: .v2)
        let plan = try await dex.prepareApproval(quote, sender: account.address)
        #expect(plan.amount == 0); #expect(plan.contract?.signature == "approve(address,uint256)"); #expect(plan.contract?.arguments.last == "1000000")
        do { _ = try await client("falseApprove").prepare(sender: account.address, invocation: plan.contract!); Issue.record("False TRC20 approval accepted") } catch {}
    }
    @Test func sunRouteRejectsHooksReferralsWrongAmountsAndForeignOutputs() throws {
        let data = try Data(contentsOf: Bundle.module.url(forResource: "sun-route-public", withExtension: "json")!)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let rows) = root["data"], case .object(let original) = rows[0] else { throw WalletError.invalid("fixture") }
        let parsed = try TronDexClient.parseRoute(rows[0], input: TronDexClient.native, output: testUSDT, amount: 1_000_000)
        #expect(parsed.hops.count == 1); #expect(parsed.hops[0].version == "v4")
        for field in ["containsUnverifiedHook", "amountInRaw", "amountOutRawReferral", "tokens", "poolKeys"] {
            var altered = original
            switch field {
            case "containsUnverifiedHook": altered[field] = .bool(true)
            case "amountInRaw": altered[field] = .string("1000001")
            case "amountOutRawReferral": altered[field] = .string("1")
            case "tokens": altered[field] = .array([.string(TronDexClient.native), .string(TronDexClient.wrapped)])
            default:
                guard case .array(let keys) = altered[field], case .object(var key) = keys[0] else { throw WalletError.invalid("fixture keys") }
                key["hooks"] = .string(testUSDT); altered[field] = .array([.object(key)])
            }
            do { _ = try TronDexClient.parseRoute(.object(altered), input: TronDexClient.native, output: testUSDT, amount: 1_000_000); Issue.record("Unsafe SUN route accepted") } catch {}
        }
        let token = try Token(chainID: TronAddress.chainID, contract: testUSDT, symbol: "USDT", decimals: 6)
        let call = try TronDexClient.invocation(mode: .smart, sender: account().address, input: nil, output: token, amount: 1_000_000, minimum: 300_000, deadline: 1_900_000_000, hops: parsed.hops)
        #expect(call.signature == "execute(bytes,bytes[],uint256)")
        let commands = try Data(strictHex: call.arguments[0]); #expect(commands.allSatisfy { $0 < 128 }); #expect(commands.first == 0x12); #expect(commands.contains(0x04))
    }
}

private struct TronApprovalMock: PrivateRequesting {
    var tokenAllowance: BigUInt = 0
    var permitAmount: BigUInt = 0
    var permitExpiry: BigUInt = 0
    func execute(_ request: PrivateRequest) async throws -> Data {
        func response(_ encoded: String) throws -> Data {
            try JSONEncoder().encode(JSONValue.object(["result": .object(["result": .bool(true)]), "constant_result": .array([.string(encoded)]), "energy_used": .number(1000)]))
        }
        if request.url.host == "open.sun.io" {
            let row: JSONValue = .object(["containsUnverifiedHook": .bool(false), "amountInRaw": .string("1000000"), "amountOutRaw": .string("2000000"), "tokens": .array([.string(testUSDT), .string(TronDexClient.wrapped)]), "poolVersions": .array([.string("v2")]), "poolFees": .array([.string("3000"), .string("0")]), "poolKeys": .array([.object([:])])])
            return try JSONEncoder().encode(JSONValue.object(["code": .number(0), "data": .array([row])]))
        }
        if request.url.path == "/wallet/triggerconstantcontract" {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
            let selector = String((body["data"]?.string ?? "").prefix(8))
            func sel(_ s: String) -> String { Data(Data(s.utf8).keccak256.prefix(4)).hexString }
            switch selector {
            case sel("allowance(address,address)"): return try response(ContractABI.word(tokenAllowance).hexString)
            case sel("allowance(address,address,address)"): return try response((ContractABI.word(permitAmount) + ContractABI.word(permitExpiry) + ContractABI.word(0)).hexString)
            case sel("balanceOf(address)"): return try response(ContractABI.word(9_000_000).hexString)
            case sel("clPoolManager()"): return try response(ContractABI.word(BigUInt(Data(strictHex: TronAddress.evm("TVjuTE3V5bMVdpfNhid8kD2v35T2k1u1Br")))).hexString)
            default: break
            }
        }
        return try await TronMock(scenario: "").execute(request)
    }
}

extension TronDexTests {
    @Test(arguments: TronDexMode.allCases)
    func approvalResetTokenPermitAndSwapAreSeparate(mode: TronDexMode) async throws {
        let owner = try account().address, chain = client().chain
        let token = try Token(chainID: chain.id, contract: testUSDT, symbol: "USDT", decimals: 6)
        let output = try Token(chainID: chain.id, contract: TronDexClient.wrapped, symbol: "WTRX", decimals: 6)
        func dex(_ allowance: BigUInt, _ permit: BigUInt = 0, _ expiry: BigUInt = 0) -> TronDexClient {
            TronDexClient(client: .init(transport: TronApprovalMock(tokenAllowance: allowance, permitAmount: permit, permitExpiry: expiry), chain: chain, isolation: "fixture"))
        }
        let empty = dex(0), quote = try await empty.quote(sender: owner, input: token, output: output, amount: "1", mode: mode)
        #expect(try await empty.approvalRequirement(quote, sender: owner) == .token)
        let approval = try await empty.prepareApproval(quote, sender: owner)
        #expect(approval.swap == nil); #expect(approval.amount == 0)
        #expect(quote.matchesApproval(try #require(approval.contract)))
        #expect(approval.contract?.arguments.last == "1000000")
        let reset = dex(1)
        #expect(try await reset.approvalRequirement(quote, sender: owner) == .reset)
        #expect(try await reset.prepareApproval(quote, sender: owner).contract?.arguments.last == "0")
        do { _ = try await empty.prepareSwap(quote, sender: owner); Issue.record("TRON swap skipped approval") } catch {}
        if mode == .smart {
            let pendingPermit = dex(1_000_000)
            #expect(try await pendingPermit.approvalRequirement(quote, sender: owner) == .permit2)
            let permit = try await pendingPermit.prepareApproval(quote, sender: owner)
            #expect(permit.contract?.signature == "approve(address,address,uint160,uint48)")
            #expect(quote.matchesApproval(try #require(permit.contract)))
        }
        let expiry = BigUInt(Int(Date().timeIntervalSince1970) + 180)
        let ready = dex(1_000_000, 1_000_000, expiry)
        let fresh = try await ready.quote(sender: owner, input: token, output: output, amount: "1", mode: mode)
        if mode == .smart { #expect(fresh.deadline == expiry) }
        #expect(try await ready.approvalRequirement(fresh, sender: owner) == .none)
        let swap = try await ready.prepareSwap(fresh, sender: owner)
        #expect(swap.swap != nil); #expect(swap.contract == fresh.invocation)
        #expect(!fresh.matchesApproval(fresh.invocation))
        do { _ = try await ready.prepareApproval(fresh, sender: owner); Issue.record("TRON repeated an existing approval") } catch {}
        let saved = NativeArchivedPlan(approval)
        #expect(saved.sameTransaction(as: approval)); #expect(!saved.sameTransaction(as: swap))
        let short = dex(1_000_000, 1_000_000, BigUInt(Int(Date().timeIntervalSince1970) + 30))
        if mode == .smart {
            let updated = try await short.quote(sender: owner, input: token, output: output, amount: "1", mode: mode)
            #expect(try await short.approvalRequirement(updated, sender: owner) == .permit2)
        }
    }

    @Test(arguments: TransactionPhase.allCases)
    func tronContinuationRequiresSolidifiedSuccessfulExecution(phase: TransactionPhase) {
        let wallet = UUID(), owner = TronDexClient.wrapped
        var item = Activity(walletID: wallet, chainID: TronAddress.chainID, hash: String(repeating: "1", count: 64), to: testUSDT, amount: "0", symbol: "TRX")
        item.transaction = .init(groupID: item.id, sender: owner, profileID: "tron", sequence: nil, nativeCost: 0, phase: phase)
        item.transaction?.observation.executionSucceeded = true; item.transaction?.observation.blockNumber = "100"
        let progress = DexApprovalProgress.resolveTron(hash: item.hash, activities: [item], walletID: wallet, sender: owner)
        if phase == .confirmed { #expect(progress == .ready) } else { #expect(progress != .ready) }
        item.transaction?.observation.executionSucceeded = nil
        #expect(DexApprovalProgress.resolveTron(hash: item.hash, activities: [item], walletID: wallet, sender: owner) != .ready)
        #expect(DexApprovalProgress.resolveTron(hash: item.hash, activities: [item], walletID: UUID(), sender: owner) != .ready)
    }
}

private struct BoundTronReceiptMock: PrivateRequesting {
    let plan: NativeTransferPlan
    let scenario: String
    func execute(_ request: PrivateRequest) async throws -> Data {
        let hash = String(repeating: "1", count: 64)
        let result: JSONValue
        if request.url.path == "/walletsolidity/gettransactioninfobyid" {
            result = .object(["id": .string(hash), "blockNumber": .number(100), "receipt": .object(["result": .string("SUCCESS")]), "contractResult": .array([.string(ContractABI.word(1).hexString)])])
        } else if request.url.path == "/walletsolidity/gettransactionbyid" {
            let call = plan.contract!
            let owner = scenario == "owner" ? testUSDT : plan.sender
            let contract = scenario == "contract" ? TronDexClient.wrapped : call.contract
            let ownerField = scenario == "base58" ? owner : "41" + String(try TronAddress.evm(owner).dropFirst(2))
            let contractField = scenario == "base58" ? contract : "41" + String(try TronAddress.evm(contract).dropFirst(2))
            result = .object(["txID": .string(hash), "ret": .array([.object(["contractRet": .string("SUCCESS")])]), "raw_data": .object(["contract": .array([.object(["type": .string("TriggerSmartContract"), "parameter": .object(["value": .object(["owner_address": .string(ownerField), "contract_address": .string(contractField), "data": .string(scenario == "data" ? "00" : call.data.hexString), "call_value": .number(scenario == "value" ? 1 : 0)])])])])])])
        } else { return try await TronMock(scenario: "").execute(request) }
        return try JSONEncoder().encode(result)
    }
}
extension TronDexTests {
    @Test(arguments: ["hex", "base58", "owner", "contract", "data", "value"])
    func approvalReceiptMustMatchTheArchivedOwnerAndCall(scenario: String) async throws {
        let owner = try account().address, chain = client().chain
        let input = try Token(chainID: chain.id, contract: testUSDT, symbol: "USDT", decimals: 6)
        let dex = TronDexClient(client: client())
        let quote = try await dex.quote(sender: owner, input: input, output: nil, amount: "1", mode: .v2)
        let plan = try await dex.prepareApproval(quote, sender: owner)
        let walletID = UUID(), hash = String(repeating: "1", count: 64)
        var item = Activity(walletID: walletID, chainID: chain.id, hash: hash, to: input.contract, amount: "0", symbol: "TRX")
        item.transaction = .native(plan, groupID: item.id); item.transaction?.broadcastAttempts = 1
        let archive = try TransactionArchive(activityID: item.id, walletID: walletID, plan: plan, signed: .init(hash: hash, family: .tron, chainID: chain.id, encoded: "public-fixture-not-for-broadcast"))
        let observer = NativeTransferClient(transport: BoundTronReceiptMock(plan: plan, scenario: scenario), chain: chain, isolation: "fixture")
        do {
            let result = try await observer.observe(activity: item, archive: archive)
            #expect(["hex", "base58"].contains(scenario)); #expect(result.phase == .confirmed)
        } catch { if ["hex", "base58"].contains(scenario) { throw error } }
    }
}

extension TronDexTests {
    @Test(arguments: ["v1", "v2", "v3", "v4", "usdt20psm", "usdd202pool", "2pool", "2pooltusdusdt", "old3pool", "oldusdcpool", "usdc2pooltusdusdt", "usdd2pooltusdusdt", "usdj2pooltusdusdt"])
    func everySUNAdapterKeepsExactInputAndFinalRecipient(version: String) throws {
        let owner = try account().address
        let input = try Token(chainID: TronAddress.chainID, contract: testUSDT, symbol: "USDT", decimals: 6)
        let output = try Token(chainID: TronAddress.chainID, contract: TronDexClient.wrapped, symbol: "WTRX", decimals: 6)
        let parameters = version == "v4" ? "0x" + ContractABI.word(60 << 16).hexString : nil
        let hop = TronDexHop(from: input.contract, to: output.contract, version: version, fee: 3000, parameters: parameters)
        let call = try TronDexClient.invocation(mode: .smart, sender: owner, input: input, output: output, amount: 1_000_000, minimum: 900_000, deadline: 1_900_000_000, hops: [hop])
        #expect(call.contract == TronDexClient.universalRouter); #expect(call.callValue == 0)
        #expect(call.signature == "execute(bytes,bytes[],uint256)")
        let commands = try Data(strictHex: call.arguments[0])
        #expect(commands.first == 0x02); #expect(commands.allSatisfy { $0 < 128 })
        let encoded = try JSONDecoder().decode([String].self, from: Data(call.arguments[1].utf8))
        let sweep = try ContractABI.parameters(types: ["address", "address", "uint160"], arguments: [TronAddress.evm(output.contract), TronAddress.evm(owner), "900000"])
        #expect(zip(commands, encoded).contains { $0.0 == 0x04 && (try? Data(strictHex: $0.1)) == sweep })
    }
}
