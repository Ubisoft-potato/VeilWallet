import Foundation

public enum NetworkFamily: String, Codable, CaseIterable, Sendable {
    case evm, bitcoin, litecoin, monero, solana, tron, sui, aptos, ton, cosmos, near, stacks, cardano, nostr, polkadot, starknet, eos
    public var name: String {
        switch self {
        case .evm: return "EVM"
        case .bitcoin: return "Bitcoin"
        case .litecoin: return "Litecoin"
        case .monero: return "Monero"
        case .solana: return "Solana"
        case .tron: return "Tron"
        case .sui: return "Sui"
        case .aptos: return "Aptos"
        case .ton: return "TON"
        case .cosmos: return "Cosmos"
        case .near: return "NEAR"
        case .stacks: return "Stacks"
        case .cardano: return "Cardano"
        case .nostr: return "Nostr"
        case .polkadot: return "Polkadot Ed25519"
        case .starknet: return "Starknet"
        case .eos: return "EOS / WAX"
        }
    }
    public var privateKeyHint: String {
        switch self {
        case .bitcoin: return L("message.wif_starting_k_l_5_or_32_byte_hexadecimal_key")
        case .litecoin: return L("message.litecoin_wif_starting_t_6_or_32_byte_hexadecimal_key")
        case .monero: return L("message.monero_native_25_word_english_seed_or_32_byte_master")
        case .solana: return L("message.base58_private_key_json_byte_array_or_32_byte_seed")
        case .sui: return L("message.suiprivkey1_ed25519_or_32_byte_hexadecimal_key")
        case .aptos: return L("message.ed25519_priv_0x_or_32_byte_hexadecimal_key")
        case .near: return L("message.ed25519_base58_json_byte_array_or_hexadecimal_key")
        case .eos: return L("message.wif_pvt_k1_or_32_byte_hexadecimal_key")
        case .starknet: return L("message.32_byte_hexadecimal_stark_curve_private_key")
        case .cardano: return L("message.128_byte_payment_stake_extended_private_key_hex")
        case .nostr: return L("message.nsec1_or_32_byte_hexadecimal_key")
        case .ton: return L("message.32_byte_ed25519_seed_or_64_byte_key_pair_hex")
        default: return L("message.32_byte_hexadecimal_private_key")
        }
    }
}
public struct AccountProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    private let nameValue: String
    public var name: String { LK(nameValue) }
    public let family: NetworkFamily
    public let pathTemplate: String
    public var variant: String = ""
    public var hrp: String = ""
    private enum CodingKeys: String, CodingKey { case id, nameValue = "name", family, pathTemplate, variant, hrp }
    public init(id: String, name: String, family: NetworkFamily, pathTemplate: String, variant: String = "", hrp: String = "") {
        self.id = id; nameValue = name; self.family = family; self.pathTemplate = pathTemplate; self.variant = variant; self.hrp = hrp
    }
    public var supportsKeyImport: Bool { id != "ltc.watch" }
    public var supportsDerivation: Bool { supportsKeyImport }
    public static var derivable: [AccountProfile] { all.filter(\.supportsDerivation) }
    public var keyHint: String { id == "ltc.mweb" ? L("message.scanprivatekey_masterspendprivatekey_subaddressindex_32_byte_hex_keys") : family.privateKeyHint }
    public var usesEd25519: Bool {
        [.solana, .sui, .aptos, .ton, .near, .polkadot].contains(family)
    }
    public func path(index: UInt32) -> String { pathTemplate.replacingOccurrences(of: "{i}", with: String(index)) }
    public static let evm = AccountProfile(id: "evm", name: "EVM · BIP44", family: .evm, pathTemplate: "m/44'/60'/0'/0/{i}")
    public static let all: [AccountProfile] = [
        evm,
        .init(id: "monero.ledger", name: "message.monero_ledger_bip39_derivation", family: .monero, pathTemplate: "m/44'/128'/{i}'/0/0", variant: "ledger"),
        .init(id: "btc.segwit", name: "Bitcoin · Native SegWit", family: .bitcoin, pathTemplate: "m/84'/0'/0'/0/{i}", variant: "segwit"),
        .init(id: "btc.legacy", name: "Bitcoin · Legacy", family: .bitcoin, pathTemplate: "m/44'/0'/0'/0/{i}", variant: "legacy"),
        .init(id: "btc.nested", name: "Bitcoin · Nested SegWit", family: .bitcoin, pathTemplate: "m/49'/0'/0'/0/{i}", variant: "nested"),
        .init(id: "btc.taproot", name: "Bitcoin · Taproot", family: .bitcoin, pathTemplate: "m/86'/0'/0'/0/{i}", variant: "taproot"),
        .init(id: "solana", name: "message.solana_four_level_path", family: .solana, pathTemplate: "m/44'/501'/{i}'/0'"),
        .init(id: "solana.legacy", name: "message.solana_three_level_path", family: .solana, pathTemplate: "m/44'/501'/{i}'"),
        .init(id: "tron", name: "Tron · BIP44", family: .tron, pathTemplate: "m/44'/195'/0'/0/{i}"),
        .init(id: "sui", name: "Sui · Ed25519", family: .sui, pathTemplate: "m/44'/784'/{i}'/0'/0'"),
        .init(id: "aptos", name: "Aptos · Ed25519", family: .aptos, pathTemplate: "m/44'/637'/{i}'/0'/0'"),
        .init(id: "ton.v4", name: "TON · Wallet V4R2", family: .ton, pathTemplate: "m/44'/607'/{i}'", variant: "v4r2"),
        .init(id: "ton.v5", name: "TON · Wallet V5R1", family: .ton, pathTemplate: "m/44'/607'/{i}'", variant: "v5r1"),
        .init(id: "near", name: "message.near_implicit_account", family: .near, pathTemplate: "m/44'/397'/{i}'"),
        .init(id: "stacks", name: "message.stacks_compressed_public_key", family: .stacks, pathTemplate: "m/44'/5757'/0'/0/{i}"),
        .init(id: "cardano", name: "Cardano · CIP-1852", family: .cardano, pathTemplate: "m/1852'/1815'/{i}'/0/0"),
        .init(id: "nostr", name: "Nostr · NIP-06", family: .nostr, pathTemplate: "m/44'/1237'/{i}'/0/0"),
        .init(id: "starknet", name: "message.starknet_stark_public_key", family: .starknet, pathTemplate: "m/44'/9004'/0'/0/{i}"),
        .init(id: "eos", name: "message.eos_k1_authority_key", family: .eos, pathTemplate: "m/44'/194'/0'/0/{i}"),
        .init(id: "wax", name: "message.wax_k1_authority_key", family: .eos, pathTemplate: "m/44'/14001'/0'/0/{i}"),
        .init(id: "polkadot.ed25519", name: "Polkadot · Ed25519 BIP44", family: .polkadot, pathTemplate: "m/44'/354'/{i}'/0'/0'")
    ] + litecoinProfiles + cosmosProfiles
    public static let litecoinProfiles: [AccountProfile] = [
        .init(id: "ltc.segwit", name: "Litecoin · Native SegWit · ltc1q", family: .litecoin, pathTemplate: "m/84'/2'/0'/0/{i}", variant: "segwit"),
        .init(id: "ltc.legacy", name: "Litecoin · Legacy · L", family: .litecoin, pathTemplate: "m/44'/2'/0'/0/{i}", variant: "legacy"),
        .init(id: "ltc.nested", name: "Litecoin · Nested SegWit · M", family: .litecoin, pathTemplate: "m/49'/2'/0'/0/{i}", variant: "nested"),
        .init(id: "ltc.nested.compat", name: "message.litecoin_legacy_p2sh_3", family: .litecoin, pathTemplate: "m/49'/2'/0'/0/{i}", variant: "nested-compat"),
        .init(id: "ltc.taproot", name: "Litecoin · Taproot · ltc1p", family: .litecoin, pathTemplate: "m/86'/2'/0'/0/{i}", variant: "taproot"),
        .init(id: "ltc.mweb", name: "Litecoin · MWEB · ltcmweb1", family: .litecoin, pathTemplate: "m/0'/100'", variant: "mweb"),
        .init(id: "ltc.watch", name: "message.litecoin_arbitrary_address_p2wsh_watch_only", family: .litecoin, pathTemplate: "", variant: "any")
    ]
    public static let cosmosProfiles: [AccountProfile] = [
        ("cosmos", "Cosmos Hub", "cosmos", 118, ""), ("osmosis", "Osmosis", "osmo", 118, ""),
        ("celestia", "Celestia", "celestia", 118, ""), ("injective", "Injective", "inj", 60, "eth"),
        ("sei.cosmos", "Sei Cosmos", "sei", 118, ""), ("juno", "Juno", "juno", 118, ""),
        ("akash", "Akash", "akash", 118, ""), ("secret", "Secret Network", "secret", 529, ""),
        ("kujira", "Kujira", "kujira", 118, ""), ("stargaze", "Stargaze", "stars", 118, ""),
        ("stride", "Stride", "stride", 118, ""), ("neutron", "Neutron", "neutron", 118, ""),
        ("dydx", "dYdX", "dydx", 118, ""), ("noble", "Noble", "noble", 118, ""),
        ("persistence", "Persistence", "persistence", 118, ""), ("axelar", "Axelar", "axelar", 118, ""),
        ("band", "Band", "band", 494, ""), ("iris", "IRISnet", "iaa", 118, ""),
        ("kava.cosmos", "Kava Cosmos", "kava", 459, ""), ("terra", "Terra", "terra", 330, ""),
        ("terra.classic", "Terra Classic", "terra", 330, ""), ("chihuahua", "Chihuahua", "chihuahua", 118, ""),
        ("sentinel", "Sentinel", "sent", 118, ""), ("comdex", "Comdex", "comdex", 118, "")
    ].map { id, name, hrp, coin, variant in
        AccountProfile(id: id, name: name + " · BIP44", family: .cosmos, pathTemplate: "m/44'/\(coin)'/0'/0/{i}", variant: variant, hrp: hrp)
    }
    public static func find(_ id: String) -> AccountProfile? { all.first { $0.id == id } }
}
public struct WalletAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: String { profileID }
    public let profileID: String
    public let address: String
    public let path: String?
    public var boundAddress: String?
    public var addressIndex: UInt32?
    public var supportsPublicBalanceQuery: Bool { profile?.family != .nostr && profile?.family != .monero && !(profile?.family == .litecoin && networkAddress.lowercased().hasPrefix("ltcmweb1")) }
    public var requiresBinding: Bool { profile?.family == .eos || profile?.family == .starknet }
    public var isBound: Bool { !requiresBinding || boundAddress != nil }
    public var networkAddress: String { boundAddress ?? address }
    public init(profileID: String, address: String, path: String? = nil, boundAddress: String? = nil, addressIndex: UInt32? = nil) { self.profileID = profileID; self.address = address; self.path = path; self.boundAddress = boundAddress; self.addressIndex = addressIndex }
    public var profile: AccountProfile? { AccountProfile.find(profileID) }
}
