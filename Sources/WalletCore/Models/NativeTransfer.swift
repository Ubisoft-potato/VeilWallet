import Foundation
import BigInt

struct NativeTransferInput: Codable, Equatable, Sendable {
    let txid: String
    let index: UInt32
    let value: String
    let previous: String
}
struct NativeTransferPayload: Codable, Equatable, Sendable {
    var from = ""; var to = ""; var amount = ""; var fee = "0"; var change = "0"
    var blockHash = ""; var nonce = "0"; var maxGas = "0"; var gasPrice = "0"; var expiration = "0"
    var refBytes = ""; var refHash = ""; var timestamp = "0"; var publicKey = ""
    var inputs: [NativeTransferInput] = []
    var chainIdentifier = ""; var denomination = ""; var accountNumber = "0"; var memo = ""
    var contractData: String?; var feeLimit: String?
    var replaceable: Bool?
}
public struct NativeTransferPlan: Sendable {
    public let chainID: UInt64
    public let profileID: String
    public let family: NetworkFamily
    public let sender: String
    public let recipient: String
    public let amount: BigUInt
    public let feeBudget: BigUInt
    public let preparedAt: Date
    public let details: [String]
    let payload: NativeTransferPayload
    let unsigned: String
    public let contract: TronInvocation?
    public let swap: TronDexQuote?
    public let bridge: BridgeQuote?
    init(chainID: UInt64, profileID: String, family: NetworkFamily, sender: String, recipient: String, amount: BigUInt, feeBudget: BigUInt, preparedAt: Date, details: [String], payload: NativeTransferPayload, unsigned: String, contract: TronInvocation? = nil, swap: TronDexQuote? = nil, bridge: BridgeQuote? = nil) {
        self.chainID = chainID; self.profileID = profileID; self.family = family; self.sender = sender; self.recipient = recipient; self.amount = amount; self.feeBudget = feeBudget; self.preparedAt = preparedAt; self.details = details; self.payload = payload; self.unsigned = unsigned; self.contract = contract; self.swap = swap
        self.bridge = bridge
    }
    public var isExpired: Bool { Date().timeIntervalSince(preparedAt) > 90 }
    public func sameTransaction(as other: NativeTransferPlan) -> Bool {
        chainID == other.chainID && family == other.family && profileID == other.profileID && sender == other.sender &&
        recipient == other.recipient && amount == other.amount && unsigned == other.unsigned && payload == other.payload && contract == other.contract
    }
    public var spentOutputs: [String] { payload.inputs.map { $0.txid.lowercased() + ":" + String($0.index) } }
    public static func supports(account: WalletAccount, chain: Chain) -> Bool {
        guard chain.profileKeys.contains(account.profileID), account.isBound else { return false }
        if [.solana, .tron, .aptos].contains(chain.family) { return true }
        if chain.family == .cosmos { return CosmosTransferConfiguration.chainIdentifiers[account.profileID] != nil }
        if [.bitcoin, .litecoin].contains(chain.family) { return account.profile?.variant != "mweb" && account.profile?.variant != "any" }
        return false
    }
}
public struct NativeSignedTransfer: Sendable {
    public let hash: String
    public let family: NetworkFamily
    public let chainID: UInt64
    let encoded: String
}
