import Testing
import Foundation
import CryptoKit
@testable import WalletCore

struct LitecoinTests {
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "multichain-reference", withExtension: "json"))))
    }
    @Test func coreAddressVectorsMatchIncludingScriptAndFutureWitness() throws {
        let resource = try #require(Bundle.module.url(forResource: "litecoin-core-addresses", withExtension: "json"))
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: resource))
        guard case .array(let valid) = file["valid"], case .array(let invalid) = file["invalid"] else { Issue.record("Missing Core fixtures"); return }
        let profile = AccountProfile.find("ltc.watch")!
        for row in valid {
            guard case .array(let values) = row, values.count == 3, let address = values[0].string, values[2]["isPrivkey"] == .bool(false) else { continue }
            let expected = values[2]["chain"] == .string("main")
            #expect(MultichainCrypto.validateAddress(address, profile: profile) == expected)
            if address.lowercased().hasPrefix("ltc1") { #expect(MultichainCrypto.validateAddress(address.uppercased(), profile: profile) == expected) }
        }
        for row in invalid {
            guard case .array(let values) = row, let address = values.first?.string else { continue }
            #expect(!MultichainCrypto.validateAddress(address, profile: profile))
        }
    }
    @Test func litecoinWIFIsNetworkSpecificAndCompressionIsPreserved() throws {
        let file = try fixture(); let keys = try #require(file["privateKeys"])
        let wif = try #require(keys["litecoinWIF"]?.string)
        let account = try MultichainCrypto.importPrivateKey(wif, profile: AccountProfile.find("ltc.segwit")!)
        #expect(account.address == file["accounts"]?["ltc.segwit"]?["address"]?.string)
        expectThrows(try MultichainCrypto.importPrivateKey(wif, profile: AccountProfile.find("btc.segwit")!))
        expectThrows(try MultichainCrypto.importPrivateKey(try #require(keys["bitcoinWIF"]?.string), profile: AccountProfile.find("ltc.segwit")!))
        let uncompressed = try #require(keys["litecoinUncompressedWIF"]?.string)
        #expect(try MultichainCrypto.importPrivateKey(uncompressed, profile: AccountProfile.find("ltc.legacy")!).address == keys["litecoinUncompressedAddress"]?.string)
        for id in ["ltc.segwit", "ltc.nested", "ltc.nested.compat", "ltc.taproot"] {
            expectThrows(try MultichainCrypto.importPrivateKey(uncompressed, profile: AccountProfile.find(id)!))
        }
        expectThrows(try MultichainCrypto.importPrivateKey(String(wif.dropLast()) + (wif.last == "1" ? "2" : "1"), profile: AccountProfile.find("ltc.legacy")!))
    }
    @Test func scriptAndCompatibilityAddressesKeepTheirMeaning() throws {
        let file = try fixture(); let keys = try #require(file["privateKeys"])
        let watch = AccountProfile.find("ltc.watch")!
        let wsh = try #require(keys["litecoinP2WSH"]?.string)
        #expect(try Litecoin.addressInfo(wsh).type == "p2wsh")
        #expect(MultichainCrypto.validateAddress(wsh, profile: watch))
        #expect(!MultichainCrypto.validateAddress(wsh, profile: AccountProfile.find("ltc.segwit")!))
        let multisig = try #require(keys["litecoinMultisig"]?.string)
        #expect(try Litecoin.addressInfo(multisig).type == "p2sh")
        let accounts = try MultichainCrypto.deriveAccounts(phrase: phrase)
        let old = try #require(accounts.first { $0.profileID == "ltc.nested.compat" })
        let current = try #require(accounts.first { $0.profileID == "ltc.nested" })
        #expect(try Litecoin.addressInfo(old.address).canonicalAddress == current.address)
        #expect(try Litecoin.addressInfo(old.address).isLegacyScriptHash)
        expectThrows(try MultichainCrypto.importPrivateKey(String(repeating: "01", count: 32), profile: watch))
    }
    @Test func mwebMatchesCoreSubaddressVectorsAndRejectsWrongKeys() throws {
        let scan = try Data(strictHex: "b3c91b7291c2e1e06d4a93f3dc32404aef9927db8e794c01a7b4de18a397c338")
        let spend = try Data(strictHex: "2fe1982b98c0b68c0839421c8a0a0a67ef3198c746ab8e6d09101eb7396a44d8")
        let vectors: [(UInt32, String)] = [
            (0, "ltcmweb1qqwkdldufg0enxpphwc8rwucc9ru6h43x5uklzm78ektgmufmw3j6kqu76qqw66w204vn7zddfgmnyq9ujugjvx4t2mhuqkuj5h4tgd8cvs6gg076"),
            (1, "ltcmweb1qqfgk4yhnh3szt08zjy0xw9qdmmf54s0e8r0szjxfk3uw2aa4q48yyq6a44z9re8jhl2khvpxdgfdj2h5wjw58fzjgu099fphh8tmhv2hcygfr2nl"),
            (10, "ltcmweb1qq0uxfh92v7n52shlndddcfad97gqycnt42gnwt56aemn0m87cxxv5qnjy0cyh9rp0mq46l2uzdwyyfp27e9jz203wzqwdvg826akasgqwvgs2kze")
        ]
        for (index, expected) in vectors {
            let actual = try Litecoin.mwebAddress(scan: scan, spend: spend, index: index)
            #expect(actual == expected)
            #expect(try Litecoin.addressInfo(actual).isMWEB)
            #expect(try Litecoin.addressInfo(actual.uppercased()).isMWEB)
            let imported = try MultichainCrypto.importPrivateKey(scan.hexString + ":" + spend.hexString + ":" + String(index), profile: AccountProfile.find("ltc.mweb")!)
            #expect(imported.address == expected); #expect(imported.addressIndex == index)
            #expect(!imported.supportsPublicBalanceQuery)
        }
        expectThrows(try Litecoin.mwebAddress(scan: Data(repeating: 0, count: 32), spend: spend))
        expectThrows(try MultichainCrypto.importPrivateKey(scan.hexString, profile: AccountProfile.find("ltc.mweb")!))
        let coreSeed = try Data(strictHex: "2a64df085eefedd8bfdbb33176b5ba2e62e8be8b56c8837795598bb6c440c064")
        let pair = try Litecoin.mwebMasterKeys(root: HDKey(seed: coreSeed), path: "m/0'/100'")
        #expect(pair.scan == scan); #expect(pair.spend == spend)
        guard case .array(let invalid) = try fixture()["invalidLitecoinAddresses"] else { Issue.record("Missing malformed address vectors"); return }
        for item in invalid { #expect(!MultichainCrypto.validateAddress(try #require(item.string), profile: AccountProfile.find("ltc.watch")!)) }
        let bad = String(vectors[0].1.dropLast()) + "q"
        #expect(!MultichainCrypto.validateAddress(bad, profile: AccountProfile.find("ltc.mweb")!))
    }
    @Test func existingMultichainVaultAddsLitecoinAndPreservesCustomAccounts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vault.json"); let vault = VaultStore(url: url); let password = "public-fixture-password"
        try await vault.create(password: password)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let custom = "m/44'/60'/3'/0/7"
        let original = try await vault.addMnemonic(name: "Previous", phrase: phrase, account: 2, overrides: ["evm": custom])
        await vault.lock()
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let salt = Data(base64Encoded: envelope["salt"] as! String)!
        let key = SymmetricKey(data: try KeyDerivation.pbkdf2(password: Data(password.utf8), salt: salt, rounds: VaultStore.rounds, count: 32))
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(base64Encoded: envelope["sealed"] as! String)!), using: key, authenticating: Data("VeilWallet.vault.v1".utf8))
        var contents = try JSONDecoder().decode(VaultContents.self, from: plain)
        let previous = original.allAccounts.filter { $0.profile?.family != .litecoin }
        contents.wallets[0].summary.accounts = previous
        let box = try AES.GCM.seal(JSONEncoder().encode(contents), using: key, authenticating: Data("VeilWallet.vault.v1".utf8))
        envelope["sealed"] = box.combined!.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let restored = try #require(try await vault.unlock(password: password).first)
        #expect(restored.id == original.id); #expect(restored.address == original.address); #expect(restored.path == custom)
        #expect(restored.allAccounts.filter { $0.profile?.family != .litecoin } == previous)
        #expect(restored.allAccounts.filter { $0.profile?.family == .litecoin }.count == 6)
        #expect(restored.allAccounts.first { $0.profileID == "ltc.mweb" }?.addressIndex == 2)
        await vault.lock()
        #expect(try await vault.unlock(password: password) == [restored])
    }
}
