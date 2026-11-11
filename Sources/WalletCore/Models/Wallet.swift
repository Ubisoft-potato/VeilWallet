import Foundation

public enum WalletKind: String, Codable, Sendable { case mnemonic, privateKey, watch }
public struct WalletSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let address: String
    public let kind: WalletKind
    public let path: String?
    public var accounts: [WalletAccount]?
    public var accountIndex: UInt32?
    public var allAccounts: [WalletAccount] { accounts ?? [WalletAccount(profileID: "evm", address: address, path: path)] }
    public func accounts(on chain: Chain) -> [WalletAccount] { allAccounts.filter { chain.profileKeys.contains($0.profileID) } }
    public var canSign: Bool { kind != .watch }
    public init(id: UUID = UUID(), name: String, address: String, kind: WalletKind, path: String? = nil, accounts: [WalletAccount]? = nil, accountIndex: UInt32? = nil) {
        self.id = id; self.name = name; self.address = address; self.kind = kind; self.path = path; self.accounts = accounts; self.accountIndex = accountIndex
    }
}
struct WalletSecret: Codable {
    var summary: WalletSummary
    var material: String
    var passphrase: String
}
struct VaultContents: Codable { var wallets: [WalletSecret] = []; var privacyNotes: [PrivacyNoteSecret]? }

public struct Chain: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UInt64
    public var name: String
    public var symbol: String
    public var rpcURL: String
    public var isTestnet: Bool
    public var familyHint: NetworkFamily?
    public var profileIDs: [String]?
    public var decimalsHint: Int?
    public var denomination: String?
    public var family: NetworkFamily { familyHint ?? .evm }
    public var isEVM: Bool { family == .evm }
    public var decimals: Int { decimalsHint ?? 18 }
    public var profileKeys: [String] { profileIDs ?? ["evm"] }
    public var configured: Bool { !rpcURL.isEmpty }
    public var canQuery: Bool { configured && family != .nostr }
    public var canTransfer: Bool { isEVM ? evmFeeModel != .unavailable : (family == .cosmos ? profileKeys.contains(where: { CosmosTransferConfiguration.chainIdentifiers[$0] != nil }) : [.bitcoin, .litecoin, .monero, .solana, .tron, .aptos].contains(family)) }

    public init(id: UInt64, name: String, symbol: String, rpcURL: String, isTestnet: Bool = false, family: NetworkFamily = .evm, profiles: [String]? = nil, decimals: Int = 18, denomination: String? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.rpcURL = rpcURL; self.isTestnet = isTestnet; self.familyHint = family == .evm ? nil : family
        self.profileIDs = profiles; self.decimalsHint = decimals == 18 ? nil : decimals; self.denomination = denomination
    }
    public static var defaults: [Chain] { NetworkCatalog.chains }
}
public struct Token: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(chainID):\(TronNetwork.isTron(chainID) ? contract : contract.lowercased())" }
    public let chainID: UInt64
    public let contract: String
    public let symbol: String
    public let decimals: Int
    public init(chainID: UInt64, contract: String, symbol: String, decimals: Int) throws {
        guard (TronNetwork.isTron(chainID) ? TronAddress.validate(contract) : Ethereum.validateAddress(contract)), (0...36).contains(decimals), !symbol.isEmpty, symbol.count <= 24,
              symbol.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw WalletError.invalid(L("message.invalid_token_information")) }
        self.chainID = chainID; self.contract = TronNetwork.isTron(chainID) ? contract : Ethereum.checksumAddress(contract); self.symbol = symbol; self.decimals = decimals
    }
}
public struct Activity: Identifiable, Codable, Sendable {
    public let id: UUID
    public let walletID: UUID
    public let chainID: UInt64
    public let hash: String
    public let to: String
    public let amount: String
    public let symbol: String
    public let date: Date
    public var status: String
    public var operation: String?
    public var bridge: BridgeTransferRecord?
    public var privacyNoteID: UUID?
    public var privacyKind: String?
    public var transaction: TransactionRecord?
    public init(walletID: UUID, chainID: UInt64, hash: String, to: String, amount: String, symbol: String) {
        id = UUID(); self.walletID = walletID; self.chainID = chainID; self.hash = hash; self.to = to
        self.amount = amount; self.symbol = symbol; date = Date(); status = WalletLocalization.legacy("receipt.pending")
    }
}
