import Testing
import Foundation
import BigInt
@testable import WalletCore

final class CryptoTests {
    let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    @Test func testBIP39OfficialVector() throws {
        expectEqual(Mnemonic.words.count, 2048)
        expectEqual(try Mnemonic.fromEntropy(Data(repeating: 0, count: 16)), phrase)
        expectTrue(Mnemonic.validate(phrase))
        expectFalse(Mnemonic.validate(String(repeating: "abandon ", count: 12)))
        expectEqual(try Mnemonic.seed(phrase: phrase, passphrase: "TREZOR").hexString,
            "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
    }
    @Test func testBIP32OfficialVector() throws {
        let key = try HDKey(seed: Data(strictHex: "000102030405060708090a0b0c0d0e0f"))
        expectEqual(key.privateKey.hexString, "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35")
        let child = try key.derived(path: "m/0'")
        expectEqual(child.privateKey.hexString, "edb2e14f9ee77d26dd93b4ecede8d16ed408ce149b6cd80b0715a2d911a0afea")
        expectEqual(child.chainCode.hexString, "47fdacbd0f1097043b78c63c20c34ef4ed9a111d980047ad16282c7ae6236141")
        expectThrows(try key.derived(path: "m/2147483648"))
    }
    @Test func testEthereumKnownAccount() throws {
        let key = try HDKey(seed: Mnemonic.seed(phrase: phrase)).derived(path: "m/44'/60'/0'/0/0")
        expectEqual(try Ethereum.address(privateKey: key.privateKey), "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let one = try Data(strictHex: String(repeating: "0", count: 63) + "1")
        expectEqual(try Ethereum.address(privateKey: one), "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
    }
    @Test func testChecksumAndAmounts() throws {
        expectTrue(Ethereum.validateAddress("0x52908400098527886E0F7030069857D2E4169EE7"))
        expectFalse(Ethereum.validateAddress("0x52908400098527886e0F7030069857D2E4169EE7"))
        expectFalse(Ethereum.validateAddress("0x0"))
        expectEqual(try Ethereum.parseUnits("1.000000000000000001"), BigUInt("1000000000000000001"))
        expectEqual(try Ethereum.parseUnits("0.000001", decimals: 6), 1)
        for value in ["1e18", "-1", " 1", "1.0000001", "1..1", ".5", "NaN"] {
            expectThrows(try Ethereum.parseUnits(value, decimals: 6))
        }
        expectEqual(Ethereum.formatUnits(try Ethereum.parseUnits("123.456"), precision: 18), "123.456")
    }
    @Test func testKeccakAndRLPVectors() throws {
        expectEqual(Data().keccak256.hexString, "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        expectEqual(RLP.bytes(Data("dog".utf8)).encoded.hexString, "83646f67")
        expectEqual(RLP.list([.bytes(Data("cat".utf8)), .bytes(Data("dog".utf8))]).encoded.hexString, "c88363617483646f67")
        expectEqual(RLP.number(0).encoded.hexString, "80")
    }
    @Test func testInvalidPrivateKeys() throws {
        expectThrows(try Ethereum.address(privateKey: Data(repeating: 0, count: 32)))
        expectThrows(try Ethereum.address(privateKey: Data(repeating: 255, count: 32)))
        expectThrows(try Ethereum.address(privateKey: Data(repeating: 1, count: 31)))
    }
    @Test func testDeterministicEIP1559() throws {
        let tx = try EVMTransaction(chainID: 1, nonce: 0, maxPriorityFee: 1_000_000_000,
            maxFee: 20_000_000_000, gasLimit: 21000, to: "0x000000000000000000000000000000000000dEaD", value: 1)
        let key = try Data(strictHex: String(repeating: "0", count: 63) + "1")
        let raw = try tx.signed(privateKey: key)
        expectEqual(raw.first, 2)
        expectEqual(raw, try tx.signed(privateKey: key))
        expectEqual(tx.maximumFee, 420_000_000_000_000)
        // External ethers reference fixture, populated by Scripts/verify-ethereum.mjs.
        let expected = "02f86b0180843b9aca008504a817c80082520894000000000000000000000000000000000000dead0180c080a043134959d73e1b4143748facfc20b0bfac587a8b253cdda5b31fa7fc58520acba0656c2f747b26b6c775e44f7154daedc24b5d45efd914081780fbdc05d01a1889"
        expectEqual(raw.hexString, expected)
    }
    @Test func testERC20Encoding() throws {
        let data = try Ethereum.transferData(to: "0x000000000000000000000000000000000000dEaD", amount: 1)
        expectEqual(data.count, 68)
        expectEqual(data.prefix(4).hexString, "a9059cbb")
        expectEqual(data.suffix(32).hexString, String(repeating: "0", count: 63) + "1")
    }
}

extension CryptoTests {
    @Test func legacyEIP155MatchesIndependentEthersSignature() throws {
        let tx = try EVMTransaction(chainID: 1, nonce: 0, maxPriorityFee: 0, maxFee: 20_000_000_000, gasLimit: 21000, to: "0x000000000000000000000000000000000000dEaD", value: 1, mode: .legacy)
        let key = try Data(strictHex: String(repeating: "0", count: 63) + "1")
        #expect(try tx.signed(privateKey: key).hexString == "f864808504a817c80082520894000000000000000000000000000000000000dead018025a040edb39c9236821e93d38556c752c1240b4b0aa55a9fecacd695fb007f492995a007f6d25626c868d49fbd1156ad65fbae46443acc2aae96d91a097490fb040351")
    }
}
