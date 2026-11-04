import Testing
import Foundation
import BigInt
@testable import WalletCore

private struct TransferReference: Decodable {
    struct Vector: Decodable { let profile: String; let material: String; let payload: NativeTransferPayload; let unsigned: String; let signed: String; let hash: String }
    struct Monero: Decodable { let phrase: String; let path: String; let address: String; let spend: String; let view: String; let nativeSeed: String }
    struct ABI: Decodable { let signature: String; let args: [String]; let encoded: String }
    let cases: [Vector]; let monero: Monero; let abi: [ABI]
    static func load() throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "transfer-reference", withExtension: "json")!)) }
}
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }

struct TransferTests {
    @Test func optionalIndependentTaprootSignatureVerification() throws {
        guard ProcessInfo.processInfo.environment["VEIL_VERIFY_NODE"] == "1" else { return }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for vector in try TransferReference.load().cases where vector.profile.hasSuffix("taproot") {
            let profile = try #require(AccountProfile.find(vector.profile))
            let result = try MultichainCrypto.execute(.init(action: "transferSign", profile: profile, key: vector.material, transfer: vector.payload))
            let signed = try #require(result.signed)
            let json = try JSONSerialization.data(withJSONObject: ["signed": signed, "inputs": vector.payload.inputs.map { ["previous": $0.previous, "txid": $0.txid, "index": $0.index] as [String: Any] }])
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", project.appendingPathComponent("Scripts/verify-taproot.cjs").path]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); try input.fileHandleForWriting.write(contentsOf: json); try input.fileHandleForWriting.close(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
    @Test func cosmosChecksNetworkSequenceSimulationAndExactFee() async throws {
        let vector = try #require(TransferReference.load().cases.first(where: { $0.profile == "cosmos" }))
        let chain = try #require(NetworkCatalog.nativeChains.first(where: { $0.profileKeys.contains("cosmos") }))
        let account = WalletAccount(profileID: "cosmos", address: vector.payload.from)
        let key = try Data(strictHex: vector.payload.publicKey)
        let good = NativeMock { request in try cosmosReply(request, vector: vector) }
        let client = NativeTransferClient(transport: good, chain: chain, isolation: "test")
        let plan = try await client.prepare(account: account, recipient: vector.payload.to, amount: "1", publicKey: key, memo: "public test memo")
        #expect(plan.feeBudget == 3250); #expect(plan.payload.maxGas == "130000"); #expect(plan.payload.chainIdentifier == "cosmoshub-4")
        #expect(plan.payload.memo == "public test memo")
        try await client.revalidate(plan, account: account)
        for changed in ["chain", "sequence", "publicKey", "simulation"] {
            let bad = NativeTransferClient(transport: NativeMock { request in try cosmosReply(request, vector: vector, changed: changed) }, chain: chain, isolation: "test")
            do { try await bad.revalidate(plan, account: account); Issue.record("Cosmos changed network/account/simulation accepted") } catch {}
        }
        let absent = NativeTransferClient(transport: NativeMock { request in
            if request.url.path.hasSuffix("/config") { return .object([:]) }
            return try cosmosReply(request, vector: vector)
        }, chain: chain, isolation: "test")
        do { _ = try await absent.prepare(account: account, recipient: vector.payload.to, amount: "1", publicKey: key); Issue.record("Missing Cosmos price guessed") } catch {}
        _ = try await absent.prepare(account: account, recipient: vector.payload.to, amount: "1", publicKey: key, gasPrice: "0.025")
        let signed = NativeSignedTransfer(hash: vector.hash, family: .cosmos, chainID: chain.id, encoded: vector.signed)
        let broadcaster = NativeTransferClient(transport: NativeMock { _ in .object(["tx_response": .object(["txhash": .string(vector.hash), "code": .number(0)])]) }, chain: chain, isolation: "test")
        #expect(try await broadcaster.broadcast(signed) == vector.hash)
    }
    @Test func nativeSigningRequiresFreshPasswordAndApprovedBytes() async throws {
        let vector = try #require(TransferReference.load().cases.first(where: { $0.profile == "btc.segwit" }))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veil-native-vault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = VaultStore(url: folder.appendingPathComponent("vault.json")), password = "public-test-password-only"
        try await vault.create(password: password)
        let wallet = try await vault.addPrivateKey(name: "test", material: vector.material, profileID: vector.profile)
        func plan(unsigned: String, date: Date = Date()) -> NativeTransferPlan {
            .init(chainID: 1, profileID: vector.profile, family: .bitcoin, sender: vector.payload.from, recipient: vector.payload.to, amount: 1_000_000, feeBudget: 10_000, preparedAt: date, details: [], payload: vector.payload, unsigned: unsigned)
        }
        do { _ = try await vault.signNative(plan: plan(unsigned: vector.unsigned), walletID: wallet.id, password: "wrong"); Issue.record("Native signature accepted stale authentication") } catch {}
        do { _ = try await vault.signNative(plan: plan(unsigned: "00"), walletID: wallet.id, password: password); Issue.record("Native changed bytes signed") } catch {}
        do { _ = try await vault.signNative(plan: plan(unsigned: vector.unsigned, date: Date().addingTimeInterval(-91)), walletID: wallet.id, password: password); Issue.record("Expired native plan signed") } catch {}
        let result = try await vault.signNative(plan: plan(unsigned: vector.unsigned), walletID: wallet.id, password: password)
        #expect(same(result.hash, vector.hash))
        await vault.lock()
        do { _ = try await vault.signNative(plan: plan(unsigned: vector.unsigned), walletID: wallet.id, password: password); Issue.record("Locked native signature accepted") } catch {}
    }
    @Test(arguments: ["btc.legacy", "btc.nested", "btc.segwit", "btc.taproot", "ltc.legacy", "ltc.nested", "ltc.segwit", "ltc.taproot", "ltc.nested.compat", "solana", "aptos", "cosmos", "injective", "tron"]) func independentUnsignedAndSignedProtocolVectors(profileID: String) throws {
        let fixture = try TransferReference.load()
        for vector in fixture.cases where vector.profile == profileID {
            let profile = try #require(AccountProfile.find(vector.profile))
            let built = try MultichainCrypto.execute(.init(action: "transferBuild", profile: profile, transfer: vector.payload))
            #expect(same(built.unsigned, vector.unsigned))
            let signed = try MultichainCrypto.execute(.init(action: "transferSign", profile: profile, key: vector.material, transfer: vector.payload))
            #expect(same(signed.unsigned, vector.unsigned))
            // Do not put signed bytes, fixture keys or addresses in assertion output.
            // btcd uses a different valid Schnorr nonce policy. Its consensus script
            // engine verifies Taproot; compare exact txid/message, not nonce bytes.
            if !profileID.hasSuffix("taproot"), !same(signed.signed, vector.signed) { Issue.record("Independent signed vector mismatch") }
            if !same(signed.hash, vector.hash) { Issue.record("Independent hash mismatch") }
        }
    }
    @Test func utxoProofCannotLieAboutAmountsScriptsOrTxids() throws {
        let vector = try #require(TransferReference.load().cases.first)
        let profile = try #require(AccountProfile.find(vector.profile))
        for field in ["value", "txid", "previous", "change"] {
            var payload = vector.payload
            let input = payload.inputs[0]
            switch field {
            case "value": payload.inputs[0] = NativeTransferInput(txid: input.txid, index: input.index, value: "3000000", previous: input.previous)
            case "txid": payload.inputs[0] = NativeTransferInput(txid: String(repeating: "1", count: 64), index: input.index, value: input.value, previous: input.previous)
            case "previous": payload.inputs[0] = NativeTransferInput(txid: input.txid, index: input.index, value: input.value, previous: String(input.previous.dropLast(2)))
            default: payload.change = "1000000"
            }
            expectThrows(try MultichainCrypto.execute(.init(action: "transferBuild", profile: profile, transfer: payload)))
        }
        var duplicate = vector.payload; duplicate.inputs += duplicate.inputs
        expectThrows(try MultichainCrypto.execute(.init(action: "transferBuild", profile: profile, transfer: duplicate)))
        let wrongKey = String(repeating: "02", count: 32)
        expectThrows(try MultichainCrypto.execute(.init(action: "transferSign", profile: profile, key: wrongKey, transfer: vector.payload)))
    }
    @Test func contractABIIsByteIdenticalToEthers() throws {
        for vector in try TransferReference.load().abi {
            let result = try ContractABI.encode(signature: vector.signature, arguments: vector.args)
            #expect(same("0x" + result.hexString, vector.encoded))
        }
        expectThrows(try ContractABI.encode(signature: "approve(address,uint256)", arguments: ["0x" + String(repeating: "0", count: 40), "-1"]))
        expectThrows(try ContractABI.encode(signature: "f(uint8)", arguments: ["256"]))
        expectThrows(try ContractABI.encode(signature: "f(bytes4)", arguments: ["0x01"]))
        expectThrows(try ContractABI.encode(signature: "f(uint256)", arguments: []))
        expectThrows(try ContractABI.encode(signature: "f(uint)", arguments: ["1"]))
        expectThrows(try ContractABI.encode(signature: "f((address,uint256))", arguments: []))
        expectThrows(try ContractABI.uint(Data([0])))
    }
    @Test func ledgerMoneroMatchesIndependentBIP39ScalarAndAddress() throws {
        let vector = try TransferReference.load().monero
        let profile = try #require(AccountProfile.find("monero.ledger"))
        let account = try #require(MultichainCrypto.deriveAccounts(phrase: vector.phrase, profiles: [profile]).first)
        #expect(same(account.address, vector.address)); #expect(same(account.path, vector.path))
        let key = try MultichainCrypto.privateKey(phrase: vector.phrase, passphrase: "", account: account)
        #expect(same(key.hexString, vector.spend))
        let imported = try MultichainCrypto.importPrivateKey(vector.spend, profile: profile)
        let nativeSeed = try MultichainCrypto.importPrivateKey(vector.nativeSeed, profile: profile)
        #expect(same(nativeSeed.address, imported.address))
        let words = vector.nativeSeed.split(separator: " ")
        let badChecksum = words.prefix(24).joined(separator: " ") + " " + (words.last == "abbey" ? "abducts" : "abbey")
        expectThrows(try MultichainCrypto.importPrivateKey(badChecksum, profile: profile))
        #expect(same(imported.address, account.address)); #expect(!account.supportsPublicBalanceQuery)
        #expect(MultichainCrypto.validateAddress(account.address, profile: profile))
        #expect(!MultichainCrypto.validateAddress(String(account.address.dropLast()) + (account.address.last == "1" ? "2" : "1"), profile: profile))
        expectThrows(try MultichainCrypto.importPrivateKey(String(repeating: "ff", count: 32), profile: profile))
        expectThrows(try MultichainCrypto.importPrivateKey(String(repeating: "00", count: 32), profile: profile))
    }
    @Test func moneroOnlyAcceptsExplicitV3HiddenServiceNodes() throws {
        #expect(try MoneroNode.validate(MoneroNode.defaultURL) == MoneroNode.defaultURL)
        for address in ["http://example.com:18081", "http://127.0.0.1:18081", "http://short.onion:80", MoneroNode.defaultURL + "/json_rpc", MoneroNode.defaultURL + "?token=x", "https://" + String(MoneroNode.defaultURL.dropFirst(7))] {
            expectThrows(try MoneroNode.validate(address))
        }
    }
    @Test @MainActor func bundledMoneroOfficialRuntimeMatchesOfflineKeys() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["VEIL_MONERO_TEST_EXECUTABLE"].map { URL(fileURLWithPath: $0) } ?? project.appendingPathComponent("Vendor/Monero/monero-wallet-rpc")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { Issue.record("Run Scripts/fetch-monero.sh for the official offline runtime validation"); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veil-monero-test-" + UUID().uuidString)
        let gate = NetworkGate(); let runtime = MoneroRuntime(executable: executable, directory: folder, gate: gate)
        defer { runtime.stop(); try? FileManager.default.removeItem(at: folder) }
        let vector = try TransferReference.load().monero
        try await runtime.open(walletID: UUID(), address: vector.address, spendKey: vector.spend, viewKey: vector.view, cachePassword: String(repeating: "01", count: 32), node: MoneroNode.defaultURL, restoreHeight: 0, offline: true)
        #expect(same(runtime.address, vector.address))
        #expect(!gate.isReady)
        do { _ = try await runtime.synchronize(); Issue.record("Offline Monero unexpectedly connected") } catch WalletError.networkBlocked {}
    }
    @Test @MainActor func moneroForwardsOnionNameThroughSOCKS4aAndCannotUseDirectFallback() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veil-monero-proxy-test-" + UUID().uuidString)
        let server = try SOCKSProbe(version: 4); let port = try await server.start()
        let gate = NetworkGate(); gate.open(port: port)
        let executable = ProcessInfo.processInfo.environment["VEIL_MONERO_TEST_EXECUTABLE"].map { URL(fileURLWithPath: $0) } ?? project.appendingPathComponent("Vendor/Monero/monero-wallet-rpc")
        let runtime = MoneroRuntime(executable: executable, directory: folder, gate: gate)
        defer { gate.close(); runtime.stop(); server.stop(); try? FileManager.default.removeItem(at: folder) }
        let vector = try TransferReference.load().monero
        do {
            try await runtime.open(walletID: UUID(), address: vector.address, spendKey: vector.spend, viewKey: vector.view, cachePassword: String(repeating: "02", count: 32), node: MoneroNode.defaultURL, restoreHeight: 0)
            do { _ = try await runtime.synchronize(); Issue.record("Rejected SOCKS connection unexpectedly synchronized") } catch {}
        } catch {}
        let actual = try await server.hostname()
        #expect(same(actual, URLComponents(string: MoneroNode.defaultURL)?.host))
        gate.close()
        do { _ = try await runtime.receipt(hash: String(repeating: "0", count: 64)); Issue.record("Closed Tor gate permitted a wallet operation") } catch WalletError.networkBlocked {}
    }
}

private struct NativeMock: PrivateRequesting {
    let handler: @Sendable (PrivateRequest) throws -> JSONValue
    func execute(_ request: PrivateRequest) async throws -> Data { try JSONEncoder().encode(handler(request)) }
}
private func cosmosReply(_ request: PrivateRequest, vector: TransferReference.Vector, changed: String = "") throws -> JSONValue {
    let path = request.url.path
    if path.contains("/by_denom") { return .object(["balance": .object(["denom": .string("uatom"), "amount": .string("9000000")])]) }
    if path.hasSuffix("/node_info") { return .object(["default_node_info": .object(["network": .string(changed == "chain" ? "wrong-mainnet" : "cosmoshub-4")])]) }
    if path.hasSuffix("/latest") { return .object(["block": .object(["header": .object(["chain_id": .string("cosmoshub-4"), "height": .string("123400"), "time": .string(ISO8601DateFormatter().string(from: Date()))])])]) }
    if path.contains("/accounts/") { return .object(["account": .object(["@type": .string("/cosmos.auth.v1beta1.BaseAccount"), "address": .string(vector.payload.from), "account_number": .string("42"), "sequence": .string(changed == "sequence" ? "8" : "7"), "pub_key": .object(["@type": .string("/cosmos.crypto.secp256k1.PubKey"), "key": .string(changed == "publicKey" ? "bad" : try Data(strictHex: vector.payload.publicKey).base64EncodedString())])])]) }
    if path.hasSuffix("/config") { return .object(["minimum_gas_price": .string("0.025uatom")]) }
    if path.hasSuffix("/simulate") {
        guard let body = request.body, let json = try? JSONDecoder().decode(JSONValue.self, from: body), json["tx_bytes"]?.string != nil else { throw WalletError.invalid("Missing simulation bytes") }
        return .object(["gas_info": .object(["gas_used": .string(changed == "simulation" ? "9000000" : "100000")])])
    }
    throw WalletError.invalid("Unexpected Cosmos test request")
}
