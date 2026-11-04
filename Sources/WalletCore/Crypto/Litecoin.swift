import Foundation

public enum Litecoin {
    public static let mainnetGenesis = "12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2"
    public struct AddressInfo: Equatable, Sendable {
        public let type: String
        public let canonicalAddress: String
        public var isMWEB: Bool { type == "mweb" }
        public var isLegacyScriptHash: Bool { type == "p2sh-legacy" }
        public var label: String {
            switch type {
            case "p2pkh": return "Legacy · P2PKH"
            case "p2sh", "p2sh-legacy": return L("message.p2sh_script_address")
            case "p2wpkh": return "Native SegWit · P2WPKH"
            case "p2wsh": return L("message.native_segwit_p2wsh_watch_only_script")
            case "p2tr": return "Taproot · P2TR"
            case "mweb": return L("message.mweb_stealth_address")
            default: return L("message.extended_witness_address_watch_only")
            }
        }
    }
    public static func addressInfo(_ address: String) throws -> AddressInfo {
        let result = try MultichainCrypto.execute(.init(action: "ltcInfo", profile: AccountProfile.find("ltc.watch")!, address: address))
        guard result.valid == true, let type = result.addressType, let canonical = result.address else { throw WalletError.invalid(L("message.invalid_litecoin_mainnet_address")) }
        return AddressInfo(type: type, canonicalAddress: canonical)
    }
    // Core's MWEB account root derives two hardened secrets; index selects the BLAKE3 subaddress.
    static func mwebMasterKeys(root: HDKey, path: String) throws -> (scan: Data, spend: Data) {
        let account = try root.derived(path: path)
        return try (account.child(0x80000000).privateKey, account.child(0x80000001).privateKey)
    }
    public static func mwebAddress(scan: Data, spend: Data, index: UInt32 = 0) throws -> String {
        _ = try Secp256k1.publicKey(privateKey: scan)
        _ = try Secp256k1.publicKey(privateKey: spend)
        let profile = AccountProfile.find("ltc.mweb")!
        let result = try MultichainCrypto.execute(.init(action: "mwebTweak", profile: profile, key: scan.hexString, index: index))
        guard let hex = result.key else { throw WalletError.invalid(L("message.mweb_subaddress_derivation_failed")) }
        let spendKey = try Secp256k1.add(privateKey: spend, tweak: Data(strictHex: hex))
        // A_i = scan * B_i; both secret scalars are available, so use constant-time secret APIs.
        let scanKey = try Secp256k1.multiply(privateKey: spendKey, tweak: scan)
        let publicPair = try Secp256k1.publicKey(privateKey: scanKey) + Secp256k1.publicKey(privateKey: spendKey)
        let encoded = try MultichainCrypto.execute(.init(action: "mwebEncode", profile: profile, key: publicPair.hexString))
        guard let address = encoded.address else { throw WalletError.invalid(L("message.mweb_address_encoding_failed")) }
        return address
    }
    static func importMWEB(_ material: String, profile: AccountProfile) throws -> WalletAccount {
        let parts = material.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        let scan: Data; let spend: Data; let index: UInt32
        if parts.count == 1 {
            let pair = try Data(strictHex: String(parts[0]))
            guard pair.count == 64 else { throw WalletError.invalid(L("message.mweb_requires_a_scan_private_key_and_master_spend_private")) }
            scan = Data(pair.prefix(32)); spend = Data(pair.suffix(32)); index = 0
        } else {
            guard (2...3).contains(parts.count), let value = parts.count == 3 ? UInt32(parts[2]) : 0 else { throw WalletError.invalid(L("message.mweb_format_scanhex_spendhex_subaddressindex")) }
            scan = try Data(strictHex: String(parts[0])); spend = try Data(strictHex: String(parts[1])); index = value
        }
        return WalletAccount(profileID: profile.id, address: try mwebAddress(scan: scan, spend: spend, index: index), addressIndex: index)
    }
}
