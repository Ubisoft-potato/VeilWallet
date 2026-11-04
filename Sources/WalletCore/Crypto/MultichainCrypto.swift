import Foundation
import CryptoKit
import CChainCore
import BigInt

public enum MultichainCrypto {
    struct Request: Encodable {
        let action: String
        let family: String
        let variant: String
        let key: String
        let address: String
        let hrp: String
        let mnemonic: String
        let passphrase: String
        let path: String
        let index: UInt32
        let transfer: NativeTransferPayload?
        let signedTransaction: String?
        init(action: String, profile: AccountProfile, key: String = "", address: String = "", mnemonic: String = "", passphrase: String = "", path: String = "", index: UInt32 = 0, transfer: NativeTransferPayload? = nil, signedTransaction: String? = nil) {
            self.action = action; family = profile.family.rawValue; variant = profile.variant; hrp = profile.hrp
            self.key = key; self.address = address; self.mnemonic = mnemonic; self.passphrase = passphrase.decomposedStringWithCompatibilityMapping; self.path = path; self.index = index
            self.transfer = transfer
            self.signedTransaction = signedTransaction
        }
    }
    struct Response: Decodable { let address: String?; let key: String?; let valid: Bool?; let error: String?; let storageKey: String?; let addressType: String?; let unsigned: String?; let signed: String?; let hash: String?; let simulation: String?; let viewKey: String?; let virtualSize: String? }
    static func execute(_ request: Request) throws -> Response {
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else { throw WalletError.invalid(L("message.multichain_request_encoding_failed")) }
        return try text.withCString { input in
            guard let output = veil_chain_execute(input) else { throw WalletError.invalid(L("message.the_multichain_cryptographic_engine_is_unavailable")) }
            defer { veil_chain_free(output) }
            let result = try JSONDecoder().decode(Response.self, from: Data(String(cString: output).utf8))
            guard result.error == nil else { throw WalletError.invalid(L("message.private_key_format_length_checksum_or_key_pair_does_not")) }
            return result
        }
    }
    public static func importPrivateKey(_ material: String, profile: AccountProfile) throws -> WalletAccount {
        guard profile.supportsKeyImport else { throw WalletError.invalid(L("message.import_script_addresses_as_watch_only_one_private_key_cannot")) }
        if profile.id == "ltc.mweb" { return try Litecoin.importMWEB(material, profile: profile) }
        if profile.family == .evm {
            let key = try Data(strictHex: material.trimmingCharacters(in: .whitespacesAndNewlines))
            return WalletAccount(profileID: profile.id, address: try Ethereum.address(privateKey: key))
        }
        let response = try execute(.init(action: "address", profile: profile, key: material))
        guard let address = response.address, !address.isEmpty else { throw WalletError.invalid(L("message.could_not_generate_an_address_for_the_selected_network")) }
        return WalletAccount(profileID: profile.id, address: address)
    }
    public static func validateAddress(_ address: String, profile: AccountProfile) -> Bool {
        if profile.family == .evm { return Ethereum.validateAddress(address) }
        return (try? execute(.init(action: "validate", profile: profile, address: address)).valid) == true
    }
    public static func deriveAccounts(phrase: String, passphrase: String = "", index: UInt32 = 0, overrides: [String: String] = [:], profiles: [AccountProfile] = AccountProfile.derivable) throws -> [WalletAccount] {
        let seed = try Mnemonic.seed(phrase: phrase, passphrase: passphrase)
        let root = try HDKey(seed: seed)
        return try profiles.filter(\.supportsDerivation).map { profile in
            let path = overrides[profile.id] ?? profile.path(index: index)
            guard path.count <= 200, path.split(separator: "/").count <= 12 else { throw WalletError.invalid(L("message.derivation_path_is_too_long")) }
            if profile.id == "ltc.mweb" {
                let pair = try Litecoin.mwebMasterKeys(root: root, path: path)
                return WalletAccount(profileID: profile.id, address: try Litecoin.mwebAddress(scan: pair.scan, spend: pair.spend, index: index), path: path, addressIndex: index)
            }
            if profile.family == .cardano {
                let response = try execute(.init(action: "cardanoDerive", profile: profile, mnemonic: Mnemonic.normalize(phrase), passphrase: passphrase, path: path))
                guard let address = response.address else { throw WalletError.invalid(L("message.cardano_derivation_failed")) }
                return WalletAccount(profileID: profile.id, address: address, path: path)
            }
            if profile.family == .monero {
                let key = try root.derived(path: path).privateKey
                let result = try execute(.init(action: "moneroDerive", profile: profile, key: key.hexString))
                guard let address = result.address else { throw WalletError.invalid(L("message.monero_derivation_failed")) }
                return WalletAccount(profileID: profile.id, address: address, path: path)
            }
            var key = try profile.usesEd25519 ? SLIP10.derive(seed: seed, path: path) : root.derived(path: path).privateKey
            if profile.family == .starknet { key = try grindStarkKey(key) }
            let account = try importPrivateKey(key.hexString, profile: profile)
            return WalletAccount(profileID: profile.id, address: account.address, path: path)
        }
    }
    static func privateKey(phrase: String, passphrase: String, account: WalletAccount) throws -> Data {
        guard let profile = account.profile, let path = account.path else { throw WalletError.invalid(L("message.the_account_lacks_derivation_information")) }
        if profile.id == "ltc.mweb" {
            let pair = try Litecoin.mwebMasterKeys(root: HDKey(seed: Mnemonic.seed(phrase: phrase, passphrase: passphrase)), path: path)
            return pair.scan + pair.spend
        }
        if profile.family == .cardano {
            let result = try execute(.init(action: "cardanoDerive", profile: profile, mnemonic: phrase, passphrase: passphrase, path: path))
            guard let key = result.key else { throw WalletError.invalid(L("message.cardano_private_key_derivation_failed")) }; return try Data(strictHex: key)
        }
        let seed = try Mnemonic.seed(phrase: phrase, passphrase: passphrase)
        if profile.family == .monero {
            let node = try HDKey(seed: seed).derived(path: path).privateKey
            guard let key = try execute(.init(action: "moneroDerive", profile: profile, key: node.hexString)).key else { throw WalletError.invalid(L("message.monero_key_derivation_failed")) }
            return try Data(strictHex: key)
        }
        let key = try profile.usesEd25519 ? SLIP10.derive(seed: seed, path: path) : HDKey(seed: seed).derived(path: path).privateKey
        return try profile.family == .starknet ? grindStarkKey(key) : key
    }
    public static func grindStarkKey(_ seed: Data) throws -> Data {
        // StarkWare rejection-sampling derivation, using CryptoKit SHA256 and exact integers.
        let order: BigUInt = "3618502788666131213697322783095070105526743751716087489154079457884512865583"
        let full = BigUInt(1) << 256
        let limit = full - full % order
        for index in 0...100_000 {
            let suffix = index == 0 ? Data([0]) : BigUInt(index).serialize()
            let candidate = BigUInt((seed + suffix).sha256Digest)
            if candidate < limit, candidate % order != 0 {
                let raw = (candidate % order).serialize()
                return Data(repeating: 0, count: 32 - raw.count) + raw
            }
        }
        throw WalletError.invalid(L("message.stark_key_derivation_exceeded_the_retry_limit"))
    }

}
public enum SLIP10 {
    // SLIP-0010 protocol derivation; HMAC is provided by CryptoKit.
    public static func derive(seed: Data, path: String) throws -> Data {
        let components = path.split(separator: "/")
        guard components.first == "m", components.count <= 12 else { throw WalletError.invalid(L("message.invalid_slip10_path")) }
        var digest = KeyDerivation.hmac512(key: Data("ed25519 seed".utf8), data: seed)
        var key = Data(digest.prefix(32)); var chain = Data(digest.suffix(32))
        for component in components.dropFirst() {
            guard component.hasSuffix("'"), let index = UInt32(component.dropLast()), index < 0x80000000 else { throw WalletError.invalid(L("message.ed25519_slip10_accepts_hardened_derivation_only")) }
            var number = (index | 0x80000000).bigEndian
            var message = Data([0]) + key
            withUnsafeBytes(of: &number) { message.append(contentsOf: $0) }
            digest = KeyDerivation.hmac512(key: chain, data: message)
            key = Data(digest.prefix(32)); chain = Data(digest.suffix(32))
        }
        return key
    }
}
