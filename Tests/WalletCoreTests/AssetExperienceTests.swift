import Foundation
import Testing
import BigInt
@testable import WalletCore

private actor AssetReadRPC: PrivateRequesting {
    let chainID: UInt64
    let decimals: Int
    let amount: BigUInt
    let runtimeOnly: Bool
    var methods: [String] = []
    init(chainID: UInt64 = 1, decimals: Int = 6, amount: BigUInt = 1_234_567, runtimeOnly: Bool = false) { self.chainID = chainID; self.decimals = decimals; self.amount = amount; self.runtimeOnly = runtimeOnly }
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!), value: JSONValue
        if request.url.path.hasSuffix("/getblockbynum") { value = .object(["blockID": .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc")]) }
        else if request.url.path.hasSuffix("/getcontract") { value = runtimeOnly ? .object([:]) : .object(["bytecode": .string("6000")]) }
        else if request.url.path.hasSuffix("/getcontractinfo") { value = .object(["runtimecode": .string("6000"), "smart_contract": .object(["contract_address": body["value"]!])]) }
        else if request.url.path.hasSuffix("/triggerconstantcontract") {
            let n = body["data"]?.string?.hasPrefix("313ce567") == true ? BigUInt(decimals) : amount
            value = .object(["result": .object(["result": .bool(true)]), "energy_used": .number(1), "constant_result": .array([.string(ContractABI.word(n).hexString)])])
        } else {
            let method = try #require(body["method"]?.string); methods.append(method)
            let result: JSONValue
            switch method {
            case "eth_chainId": result = .string(Ethereum.quantity(BigUInt(chainID)))
            case "eth_getCode": result = .string("0x6000")
            case "eth_getBalance": result = .string(Ethereum.quantity(amount))
            case "eth_call":
                guard case .array(let args) = body["params"] else { throw WalletError.invalid("Asset fixture params") }
                result = .string("0x" + ContractABI.word(args[0]["data"]?.string == "0x313ce567" ? BigUInt(decimals) : amount).hexString)
            default: throw WalletError.invalid("Unexpected asset read method")
            }
            value = .object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result])
        }
        return try JSONEncoder().encode(value)
    }
}
struct AssetExperienceTests {
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    @Test func idleLockDefaultsAndLegacyMetadataMigration() throws {
        var prefs = WalletPreferences()
        #expect(prefs.autoLockMinutes == 30); #expect(!prefs.shouldLock(idleSeconds: 1799)); #expect(prefs.shouldLock(idleSeconds: 1800))
        #expect(prefs.autoRefreshAssets); #expect(prefs.scanScope == .common)
        prefs.autoLockMinutes = 5; #expect(prefs.shouldLock(idleSeconds: 300)); #expect(!prefs.shouldLock(idleSeconds: 299))
        prefs.autoLockMinutes = -1; #expect(prefs.lockInterval == 1800)
        let old = try JSONDecoder().decode(LocalStore.State.self, from: Data("{\"chains\":[],\"tokens\":[],\"activities\":[]}".utf8))
        #expect(old.preferences == nil); #expect(old.assetBalances == nil)
        #expect((old.preferences ?? WalletPreferences()).autoLockMinutes == 30)
    }
    @Test func presetsKeepChainIdentityAndLegacyAssetsExplicit() throws {
        #expect(TokenCatalog.all.count >= 59)
        #expect(Set(TokenCatalog.all.map(\.id)).count == TokenCatalog.all.count)
        let eth = try #require(TokenCatalog.all.first { $0.chainID == 1 && $0.symbol == "USDT" })
        let bsc = try #require(TokenCatalog.all.first { $0.chainID == 56 && $0.symbol == "USDT" })
        #expect(eth.decimals == 6); #expect(bsc.decimals == 18); #expect(bsc.provenance == "Binance-Peg")
        let tron = TokenCatalog.all.filter { $0.chainID == TronAddress.chainID }
        #expect(Set(tron.map(\.symbol)).isSuperset(of: ["USDT","USDD","SUN","JST","WTRX","USDDOLD","USDCOLD"]))
        #expect(!tron.contains { $0.symbol == "USDC" })
        let current = try #require(tron.first { $0.symbol == "USDD" })
        #expect(current.contract == "TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz")
        let spoof = try Token(chainID: 1, contract: eth.contract, symbol: "FAKE", decimals: 18)
        let merged = TokenCatalog.merged(with: [spoof,spoof])
        #expect(merged.filter { $0.id == eth.id }.count == 1)
        #expect(merged.first { $0.id == eth.id }?.decimals == 6)
        for preset in TokenCatalog.all { #expect(AssetArtwork.url(preset.logo) != nil) }
    }
    @Test func plannerSeparatesWalletsScopesAndProtectsLocalScanAccounts() throws {
        let ids = ["evm","tron","monero.ledger","ltc.nested","ltc.nested.compat","ltc.mweb"]
        let accounts = try MultichainCrypto.deriveAccounts(phrase: phrase, profiles: ids.compactMap(AccountProfile.find))
        let wallet = WalletSummary(name: "public fixture", address: accounts[0].address, kind: .watch, accounts: accounts)
        let selected = PortfolioPlanner.queries(wallet: wallet, chains: Chain.defaults, customTokens: [], scope: .selected, selectedChain: 56, selectedProfile: "evm")
        #expect(!selected.isEmpty); #expect(selected.allSatisfy { $0.chain.id == 56 && $0.walletID == wallet.id })
        let common = PortfolioPlanner.queries(wallet: wallet, chains: Chain.defaults, customTokens: [], scope: .common, selectedChain: 1, selectedProfile: "evm")
        #expect(common.contains { $0.chain.family == .tron && $0.token?.symbol == "USDT" })
        #expect(!common.contains { $0.chain.isTestnet })
        #expect(common.contains { $0.chain.family == .monero && !$0.automatic })
        #expect(common.contains { $0.account.profileID == "ltc.mweb" && !$0.automatic })
        // M... and compatibility 3... represent the same Litecoin script.
        #expect(common.filter { $0.account.profileID == "ltc.nested" || $0.account.profileID == "ltc.nested.compat" }.count == 1)
        #expect(Set(common.map(\.id)).count == common.count)
    }
    @Test func tokenBalancesRequireCorrectNetworkAndOnchainPrecision() async throws {
        let chain = Chain.defaults.first { $0.id == 1 }!, token = try #require(TokenCatalog.all.first { $0.chainID == 1 && $0.symbol == "USDC" }).token
        let account = WalletAccount(profileID: "evm", address: "0x000000000000000000000000000000000000dEaD")
        let query = AssetQuery(walletID: UUID(), chain: chain, account: account, token: token)
        let rpc = AssetReadRPC(), client = PortfolioClient(transport: rpc, isolation: "fixture")
        #expect(try await client.balance(query) == 1_234_567)
        let methods = await rpc.methods
        #expect(methods.contains("eth_chainId")); #expect(methods.contains("eth_getCode")); #expect(!methods.contains("eth_sendRawTransaction"))
        for bad in [AssetReadRPC(chainID: 56),AssetReadRPC(decimals: 18)] {
            do { _ = try await PortfolioClient(transport: bad, isolation: "fixture").balance(query); Issue.record("Wrong network / decimals displayed as balance") } catch {}
        }
        let wrongToken = try Token(chainID: 56, contract: token.contract, symbol: "USDC", decimals: 6)
        let invalid = AssetQuery(walletID: query.walletID, chain: chain, account: account, token: wrongToken)
        #expect(!invalid.automatic)
    }
    @Test func tronBalancesVerifyPrecisionAndFailuresPreserveLastKnownValue() async throws {
        let account = try #require(MultichainCrypto.deriveAccounts(phrase: phrase, profiles: [AccountProfile.find("tron")!]).first)
        let chain = Chain.defaults.first { $0.family == .tron }!, token = TokenCatalog.all.first { $0.chainID == chain.id && $0.symbol == "USDT" }!.token
        let query = AssetQuery(walletID: UUID(), chain: chain, account: account, token: token)
        let amount = try await PortfolioClient(transport: AssetReadRPC(), isolation: "fixture").balance(query)
        #expect(amount == 1_234_567)
        #expect(try await PortfolioClient(transport: AssetReadRPC(runtimeOnly: true), isolation: "fixture").balance(query) == amount)
        do { _ = try await PortfolioClient(transport: AssetReadRPC(decimals: 18), isolation: "fixture").balance(query); Issue.record("TRC20 precision mismatch accepted") } catch {}
        let success = AssetBalanceSnapshot(query: query, balance: amount)
        let failed = AssetBalanceSnapshot(query: query, balance: nil, error: "fixture timeout", previous: success)
        #expect(failed.balance == success.balance); #expect(failed.error != nil); #expect(failed.updatedAt == success.updatedAt)
        let unknown = AssetBalanceSnapshot(query: query, balance: nil, error: "fixture timeout")
        #expect(unknown.balance == nil)
        var changed = chain; changed.rpcURL = "https://different.example.invalid"
        #expect(!success.matches(.init(walletID: query.walletID, chain: changed, account: account, token: token)))
        let changedQuery = AssetQuery(walletID: query.walletID, chain: changed, account: account, token: token)
        #expect(AssetBalanceSnapshot(query: changedQuery, balance: nil, error: "fixture", previous: success).balance == nil)
        let changedPrecision = try Token(chainID: chain.id, contract: token.contract, symbol: token.symbol, decimals: 18)
        #expect(!success.matches(.init(walletID: query.walletID, chain: chain, account: account, token: changedPrecision)))
    }
}
