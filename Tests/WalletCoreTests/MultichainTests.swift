import Testing
import Foundation
import CryptoKit
@testable import WalletCore

private struct Reference: Decodable {
    struct Account: Decodable { let path: String; let address: String }
    let phrase: String
    let accounts: [String: Account]
    let privateKeys: [String: String]
    static func load() throws -> Reference {
        let url = try #require(Bundle.module.url(forResource: "multichain-reference", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
struct MultichainTests {
    @Test func independentAddressesAcrossTwentyFourProfiles() throws {
        let reference = try Reference.load()
        let accounts = try MultichainCrypto.deriveAccounts(phrase: reference.phrase)
        #expect(accounts.count == AccountProfile.derivable.count)
        #expect(Set(accounts.map(\.profileID)).count == accounts.count)
        for (id, expected) in reference.accounts {
            let actual = try #require(accounts.first { $0.profileID == id })
            #expect(actual.path == expected.path)
            if id == "starknet" {
                #expect(actual.address.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "0")) == expected.address.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "0")))
            } else { #expect(actual.address == expected.address) }
        }
        for account in accounts where !account.requiresBinding {
            let profile = try #require(account.profile)
            #expect(MultichainCrypto.validateAddress(account.address, profile: profile))
        }
    }
    @Test func privateKeyFormatsRoundTripAndRejectBadKeypairs() throws {
        let r = try Reference.load()
        let samples = [("solana", "solanaBase58"), ("solana", "solanaJSON"), ("solana", "solanaSeed"), ("btc.segwit", "bitcoinWIF"), ("sui", "suiBech32"), ("aptos", "aptosAIP80"), ("starknet", "starkKey"), ("eos", "eosWIF"), ("eos", "eosPVT"), ("near", "nearKey"), ("nostr", "nostrKey"), ("cardano", "cardanoKey"), ("ton.v4", "tonPair"), ("ltc.segwit", "litecoinWIF"), ("ltc.mweb", "litecoinMwebPair")]
        for (id, keyName) in samples {
            let account = try MultichainCrypto.importPrivateKey(try #require(r.privateKeys[keyName]), profile: try #require(AccountProfile.find(id)))
            let expected = try #require(r.accounts[id]?.address)
            #expect(account.address == expected)
        }
        let eos = try #require(r.privateKeys["eosPVT"])
        expectThrows(try MultichainCrypto.importPrivateKey(String(eos.dropLast()) + (eos.last == "1" ? "2" : "1"), profile: AccountProfile.find("eos")!))
        var pair = try #require(r.privateKeys["solanaJSON"]).data(using: .utf8).map { try JSONDecoder().decode([UInt8].self, from: $0) }!
        pair[63] ^= 1
        let malformed = String(data: try JSONEncoder().encode(pair), encoding: .utf8)!
        expectThrows(try MultichainCrypto.importPrivateKey(malformed, profile: AccountProfile.find("solana")!))
        let zeroBase58 = String(repeating: "1", count: 32)
        #expect(try MultichainCrypto.importPrivateKey(zeroBase58, profile: AccountProfile.find("solana")!).address.count > 30)
    }
    @Test func rejectsWrongNetworkAndMalformedPublicIdentities() throws {
        for (id, address) in [
            ("nostr", "npub1qy6sjm9n"),
            ("ton.v4", "0QAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-akS"),
            ("cardano", "addr1qq8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mqytq293")
        ] {
            #expect(!MultichainCrypto.validateAddress(address, profile: AccountProfile.find(id)!))
        }
    }
    @Test func uncompressedBitcoinWIFRequiresLegacy() throws {
        let r = try Reference.load(); let key = try #require(r.privateKeys["legacyUncompressedWIF"])
        let legacy = try MultichainCrypto.importPrivateKey(key, profile: AccountProfile.find("btc.legacy")!)
        #expect(legacy.address == r.privateKeys["legacyUncompressedAddress"])
        expectThrows(try MultichainCrypto.importPrivateKey(key, profile: AccountProfile.find("btc.segwit")!))
        expectThrows(try MultichainCrypto.importPrivateKey(String(key.dropLast()) + "0", profile: AccountProfile.find("btc.legacy")!))
    }
    @Test func separateNetworkSemanticsAndHardenedDerivation() throws {
        let r = try Reference.load()
        let accounts0 = try MultichainCrypto.deriveAccounts(phrase: r.phrase)
        let accounts1 = try MultichainCrypto.deriveAccounts(phrase: r.phrase, index: 1)
        for id in ["evm", "btc.segwit", "solana", "cardano", "ton.v4"] {
            #expect(accounts0.first { $0.profileID == id }?.address != accounts1.first { $0.profileID == id }?.address)
        }
        expectThrows(try SLIP10.derive(seed: Data(repeating: 1, count: 32), path: "m/44'/501'/0/0"))
        let withA = try Mnemonic.seed(phrase: r.phrase, passphrase: "é")
        let withB = try Mnemonic.seed(phrase: r.phrase, passphrase: "e\u{301}")
        #expect(withA == withB)
    }
    @Test func catalogAndCompatibilityAreExplicit() throws {
        #expect(Chain.defaults.count > 100)
        #expect(Set(Chain.defaults.map(\.id)).count == Chain.defaults.count)
        for chain in Chain.defaults {
            #expect(!chain.profileKeys.isEmpty)
            #expect(chain.profileKeys.allSatisfy { AccountProfile.find($0) != nil })
            if chain.configured {
                if chain.family == .monero { _ = try MoneroNode.validate(chain.rpcURL) }
                else { try PrivateRequest.validate(try #require(URL(string: chain.rpcURL))) }
            }
        }
        let sol = WalletSummary(name: "Solana", address: "address", kind: .privateKey, accounts: [.init(profileID: "solana", address: "address")])
        #expect(sol.accounts(on: Chain.defaults.first { $0.id == 1 }!).isEmpty)
        #expect(sol.accounts(on: NetworkCatalog.nativeChains.first { $0.family == .solana }!).count == 1)
        #expect(NetworkCatalog.mergeDefaults(into: [Chain.defaults[0]]).count == Chain.defaults.count)
    }
    @Test func nativeVaultCannotSignEVMAndKeepsImportedFormat() async throws {
        let r = try Reference.load(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json")); let password = "public-test-password-long"
        try await vault.create(password: password)
        let key = try #require(r.privateKeys["solanaBase58"])
        let wallet = try await vault.addPrivateKey(name: "Solana", material: key, profileID: "solana")
        #expect(wallet.allAccounts.count == 1)
        #expect(wallet.address == r.accounts["solana"]?.address)
        let tx = try EVMTransaction(chainID: 1, nonce: 0, maxPriorityFee: 1, maxFee: 2, gasLimit: 21000, to: "0x000000000000000000000000000000000000dEaD", value: 1)
        do { _ = try await vault.sign(transaction: tx, walletID: wallet.id, password: password); Issue.record("Solana key was reinterpreted as EVM") } catch {}
        await vault.lock(); let restored = try await vault.unlock(password: password)
        #expect(restored == [wallet])
        let revealed = try await vault.reveal(walletID: wallet.id, password: password)
        #expect(revealed.material == key)
        let encrypted = try String(contentsOf: directory.appendingPathComponent("vault.json"), encoding: .utf8)
        #expect(!encrypted.contains(key))
    }
}

extension MultichainTests {
    @Test func migratesExistingEVMVaultWithoutChangingAddressOrID() async throws {
        let reference = try Reference.load()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vault.json")
        let vault = VaultStore(url: url); let password = "public-fixture-password"
        try await vault.create(password: password)
        let original = try await vault.addMnemonic(name: "Original", phrase: reference.phrase, account: 1)
        await vault.lock()
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let salt = try #require(Data(base64Encoded: envelope["salt"] as! String))
        let key = SymmetricKey(data: try KeyDerivation.pbkdf2(password: Data(password.utf8), salt: salt, rounds: VaultStore.rounds, count: 32))
        let sealed = try AES.GCM.SealedBox(combined: Data(base64Encoded: envelope["sealed"] as! String)!)
        let plain = try AES.GCM.open(sealed, using: key, authenticating: Data("VeilWallet.vault.v1".utf8))
        var payload = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        var records = payload["wallets"] as! [[String: Any]]
        var summary = records[0]["summary"] as! [String: Any]
        summary.removeValue(forKey: "accounts"); summary.removeValue(forKey: "accountIndex")
        records[0]["summary"] = summary; payload["wallets"] = records
        let old = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload), using: key, authenticating: Data("VeilWallet.vault.v1".utf8))
        envelope["sealed"] = old.combined!.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let restored = try await vault.unlock(password: password)
        #expect(restored[0].id == original.id)
        #expect(restored[0].address == original.address)
        #expect(restored[0].path == original.path)
        #expect(restored[0].allAccounts.count == AccountProfile.derivable.count)
        #expect(restored[0].accountIndex == 1)
    }
    @Test func customDerivationPathsAreStoredAndValidated() async throws {
        let reference = try Reference.load()
        let path = "m/44'/60'/1'/0/0"
        let accounts = try MultichainCrypto.deriveAccounts(phrase: reference.phrase, overrides: ["evm": path])
        let evm = try #require(accounts.first { $0.profileID == "evm" })
        #expect(evm.path == path)
        let expected = try Ethereum.address(privateKey: HDKey(seed: Mnemonic.seed(phrase: reference.phrase)).derived(path: path).privateKey)
        #expect(evm.address == expected)
        expectThrows(try MultichainCrypto.deriveAccounts(phrase: reference.phrase, overrides: ["solana": "m/44'/501'/0/0"]))
        expectThrows(try MultichainCrypto.deriveAccounts(phrase: reference.phrase, overrides: ["cardano": "m/44'/1815'/0'/0/0"]))
    }
}
