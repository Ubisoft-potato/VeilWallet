import Testing
import Foundation
import BigInt
@testable import WalletCore

private struct NativeMock: PrivateRequesting {
    let handler: @Sendable (String, JSONValue?) throws -> JSONValue
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try request.body.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        let response = try handler(request.url.path, body)
        if let id = body?["id"] {
            return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": response]))
        }
        return try JSONEncoder().encode(response)
    }
}
struct NativeBalanceTests {
    @Test func solanaRequiresMainnetAndPreservesIntegerUnits() async throws {
        let profile = AccountProfile.find("solana")!
        let account = try MultichainCrypto.importPrivateKey(String(repeating: "00", count: 32), profile: profile)
        let chain = NetworkCatalog.nativeChains.first { $0.family == .solana }!
        let mock = NativeMock { _, body in
            switch body?["method"]?.string {
            case "getGenesisHash": return .string("5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d")
            case "getBalance": return .object(["value": .number(123_456_789)])
            default: throw WalletError.invalid("Unexpected method")
            }
        }
        let result = try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: account)
        #expect(result == 123_456_789)
        let wrong = NativeMock { _, _ in .string("wrong-genesis") }
        do { _ = try await NativeBalanceClient(transport: wrong, chain: chain, isolation: "test").balance(account: account); Issue.record("Wrong chain accepted") } catch {}
    }
    @Test func suiGraphQLRejectsPartialErrorsAndWrongNetwork() async throws {
        let account = try MultichainCrypto.importPrivateKey(String(repeating: "01", count: 32), profile: AccountProfile.find("sui")!)
        let chain = NetworkCatalog.nativeChains.first { $0.family == .sui }!
        let mock = NativeMock { path, body in
            #expect(path == "/graphql")
            #expect(body?["variables"]?["address"] == .string(account.address))
            #expect(body?["method"] == nil)
            return .object(["data": .object(["chainIdentifier": .string("4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"), "address": .object(["balance": .object(["totalBalance": .string("98765432109876543210")])])])])
        }
        #expect(try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: account) == BigUInt("98765432109876543210"))
        for response in [JSONValue.object(["errors": .array([.object(["message": .string("partial failure")])])]), .object(["data": .object(["chainIdentifier": .string("4c78adac")])])] {
            let bad = NativeMock { _, _ in response }
            do { _ = try await NativeBalanceClient(transport: bad, chain: chain, isolation: "test").balance(account: account); Issue.record("Invalid Sui response accepted") } catch {}
        }
    }
    @Test func tonCenterChecksExplicitSuccessEnvelope() async throws {
        let account = try MultichainCrypto.importPrivateKey(String(repeating: "01", count: 32), profile: AccountProfile.find("ton.v4")!)
        let chain = NetworkCatalog.nativeChains.first { $0.family == .ton }!
        let mock = NativeMock { path, body in
            #expect(path == "/api/v2/getAddressBalance"); #expect(body?["address"] == .string(account.address))
            return .object(["ok": .bool(true), "result": .string("1234567890")])
        }
        #expect(try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: account) == 1234567890)
        let error = NativeMock { _, _ in .object(["ok": .bool(false), "result": .string("0")]) }
        do { _ = try await NativeBalanceClient(transport: error, chain: chain, isolation: "test").balance(account: account); Issue.record("Failed TON response accepted") } catch {}
    }
    @Test func absentTronAccountMeansZeroButMalformedNumbersFail() async throws {
        let profile = AccountProfile.find("tron")!
        let account = try MultichainCrypto.importPrivateKey(String(repeating: "0", count: 63) + "1", profile: profile)
        let chain = NetworkCatalog.nativeChains.first { $0.family == .tron }!
        let empty = NativeMock { path, body in
            if path == "/wallet/getblockbynum" { return .object(["blockID": .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc")]) }
            #expect(path == "/wallet/getaccount")
            #expect(body?["visible"] == .bool(true)); return .object([:])
        }
        #expect(try await NativeBalanceClient(transport: empty, chain: chain, isolation: "test").balance(account: account) == 0)
        let malformed = NativeMock { path, _ in
            if path == "/wallet/getblockbynum" { return .object(["blockID": .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc")]) }
            return .object(["balance": .number(-1)])
        }
        do { _ = try await NativeBalanceClient(transport: malformed, chain: chain, isolation: "test").balance(account: account); Issue.record("Negative amount accepted") } catch {}
        let wrongNetwork = NativeMock { _, _ in .object(["blockID": .string(String(repeating: "0", count: 64))]) }
        do { _ = try await NativeBalanceClient(transport: wrongNetwork, chain: chain, isolation: "test").balance(account: account); Issue.record("Tron foreign genesis accepted") } catch {}
    }
    @Test func cosmosUsesDenominationAndDoesNotUseEVMRPC() async throws {
        let accounts = try MultichainCrypto.deriveAccounts(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let account = accounts.first { $0.profileID == "cosmos" }!
        let chain = NetworkCatalog.nativeChains.first { $0.profileKeys == ["cosmos"] }!
        let mock = NativeMock { path, body in
            #expect(body == nil)
            #expect(path.contains("cosmos/bank/v1beta1/balances/"))
            return .object(["balance": .object(["denom": .string("uatom"), "amount": .string("123456789012345678901234")])])
        }
        let amount = try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: account)
        #expect(amount == BigUInt("123456789012345678901234"))
    }
    @Test func permissionsPublicKeyIsNotSilentlyUsedAsRecipient() async throws {
        let account = try MultichainCrypto.importPrivateKey(String(repeating: "0", count: 63) + "1", profile: AccountProfile.find("starknet")!)
        #expect(account.requiresBinding)
        #expect(!account.isBound)
        let chain = NetworkCatalog.nativeChains.first { $0.family == .starknet }!
        let mock = NativeMock { _, _ in Issue.record("Unbound permission key made an RPC request"); return .null }
        do { _ = try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: account); Issue.record("Unbound key queried") } catch {}
    }
    @Test func polkadotReadsKnownAccountInfoLayout() async throws {
        let account = try MultichainCrypto.importPrivateKey(String(repeating: "01", count: 32), profile: AccountProfile.find("polkadot.ed25519")!)
        let chain = NetworkCatalog.nativeChains.first { $0.family == .polkadot }!
        let mock = NativeMock { _, body in
            if body?["method"]?.string == "state_getRuntimeVersion" { return .object(["specName": .string("polkadot")]) }
            #expect(body?["method"] == .string("state_getStorage"))
            var bytes = Data(repeating: 0, count: 80); bytes[16] = 42
            return .string("0x" + bytes.hexString)
        }
        #expect(try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: account) == 42)
    }
}

private struct LitecoinBalanceMock: PrivateRequesting {
    let genesis: String
    let canonical: String
    let negative: Bool
    func execute(_ request: PrivateRequest) async throws -> Data {
        #expect(request.body == nil)
        if request.url.path == "/api/block-height/0" { return Data(genesis.utf8) }
        #expect(request.url.path == "/api/address/" + canonical)
        let funded = negative ? -1 : 1000
        return try JSONEncoder().encode(JSONValue.object([
            "chain_stats": .object(["funded_txo_sum": .number(funded), "spent_txo_sum": .number(350)]),
            "mempool_stats": .object(["funded_txo_sum": .number(25), "spent_txo_sum": .number(5)])
        ]))
    }
}
extension NativeBalanceTests {
    @Test func litecoinChecksGenesisAndCanonicalizesOldP2SH() async throws {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let accounts = try MultichainCrypto.deriveAccounts(phrase: phrase)
        let old = try #require(accounts.first { $0.profileID == "ltc.nested.compat" })
        let current = try #require(accounts.first { $0.profileID == "ltc.nested" })
        let chain = try #require(NetworkCatalog.nativeChains.first { $0.family == .litecoin })
        let good = LitecoinBalanceMock(genesis: Litecoin.mainnetGenesis, canonical: current.address, negative: false)
        #expect(try await NativeBalanceClient(transport: good, chain: chain, isolation: "test").balance(account: old) == 670)
        let wrongChain = LitecoinBalanceMock(genesis: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f", canonical: current.address, negative: false)
        do { _ = try await NativeBalanceClient(transport: wrongChain, chain: chain, isolation: "test").balance(account: old); Issue.record("Bitcoin genesis accepted for Litecoin") } catch {}
        let malformed = LitecoinBalanceMock(genesis: Litecoin.mainnetGenesis, canonical: current.address, negative: true)
        do { _ = try await NativeBalanceClient(transport: malformed, chain: chain, isolation: "test").balance(account: old); Issue.record("Negative LTC statistics accepted") } catch {}
    }
    @Test func mwebNeverSendsAddressOrScanKeyToPublicBalanceAPI() async throws {
        let accounts = try MultichainCrypto.deriveAccounts(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let mweb = try #require(accounts.first { $0.profileID == "ltc.mweb" })
        let chain = try #require(NetworkCatalog.nativeChains.first { $0.family == .litecoin })
        let mock = NativeMock { _, _ in Issue.record("MWEB data reached public API"); return .null }
        do { _ = try await NativeBalanceClient(transport: mock, chain: chain, isolation: "test").balance(account: mweb); Issue.record("MWEB public balance query allowed") } catch {}
    }
}
