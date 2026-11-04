import Foundation
import BigInt

public struct PrivacyPool: Identifiable, Equatable, Sendable {
    public let id: String
    public let chainID: UInt64
    public let currency: String
    public let denomination: String
    public let contract: String
    public let deploymentBlock: UInt64
    public var amount: BigUInt { get throws { try Ethereum.parseUnits(denomination, decimals: 18) } }
    public var name: String { denomination + " " + currency.uppercased() + " · Tornado Classic" }
}
public enum PrivacyPoolCatalog {
    public static let pools: [PrivacyPool] = [
        .init(id: "tornado-eth-0.1", chainID: 1, currency: "eth", denomination: "0.1", contract: "0x12D66f87A04A9E220743712cE6d9bB1B5616B8Fc", deploymentBlock: 9116966),
        .init(id: "tornado-eth-1", chainID: 1, currency: "eth", denomination: "1", contract: "0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936", deploymentBlock: 9117609),
        .init(id: "tornado-eth-10", chainID: 1, currency: "eth", denomination: "10", contract: "0x910Cbd523D972eb0a6f4cAe4618aD62622b39DbF", deploymentBlock: 9117720),
        .init(id: "tornado-eth-100", chainID: 1, currency: "eth", denomination: "100", contract: "0xA160cdAB225685dA1d56aa342Ad8841c3b53f291", deploymentBlock: 9161895),
        .init(id: "tornado-bnb-0.1", chainID: 56, currency: "bnb", denomination: "0.1", contract: "0x84443CFd09A48AF6eF360C6976C5392aC5023a1F", deploymentBlock: 8159279),
        .init(id: "tornado-bnb-1", chainID: 56, currency: "bnb", denomination: "1", contract: "0xd47438C816c9E7f2E2888E060936a499Af9582b3", deploymentBlock: 8159286),
        .init(id: "tornado-bnb-10", chainID: 56, currency: "bnb", denomination: "10", contract: "0x330bdFADE01eE9bF63C209Ee33102DD334618e0a", deploymentBlock: 8159290),
        .init(id: "tornado-bnb-100", chainID: 56, currency: "bnb", denomination: "100", contract: "0x1E34A77868E19A6647b1f2F47B51ed72dEDE95DD", deploymentBlock: 8159296)
    ]
    public static func find(_ id: String) -> PrivacyPool? { pools.first { $0.id == id } }
    public static func on(_ id: UInt64) -> [PrivacyPool] { pools.filter { $0.chainID == id } }
}
public struct PrivacyNoteSummary: Identifiable, Codable, Sendable {
    public let id: UUID
    public let walletID: UUID?
    public let poolID: String
    public let commitment: String
    public let createdAt: Date
    public var depositHash: String?
    public var depositSender: String?
    public var withdrawalHash: String?
    public var attempts: [PrivacyTransactionAttempt]?
    public var pool: PrivacyPool? { PrivacyPoolCatalog.find(poolID) }
}
public struct PrivacyTransactionAttempt: Codable, Sendable {
    public let hash: String
    public let kind: PrivacyTransactionIntent.Kind
    public let cancellation: Bool
}
struct PrivacyNoteSecret: Codable, Sendable { var summary: PrivacyNoteSummary; let material: String }
public struct PrivacyNoteMaterial: Sendable {
    public let pool: PrivacyPool
    let preimage: String
    public let canonical: String
    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "tornado", let chainID = UInt64(parts[3]),
              let pool = PrivacyPoolCatalog.pools.first(where: { $0.chainID == chainID && $0.currency == parts[1] && $0.denomination == parts[2] }),
              parts[4].hasPrefix("0x"), let bytes = try? Data(strictHex: String(parts[4])), bytes.count == 62 else { throw WalletError.invalid(L("message.only_standard_tornado_notes_for_fixed_eth_bsc_native_asset")) }
        self.pool = pool; preimage = bytes.hexString
        canonical = "tornado-" + pool.currency + "-" + pool.denomination + "-" + String(pool.chainID) + "-0x" + preimage
    }
    static func create(pool: PrivacyPool) throws -> PrivacyNoteMaterial {
        try .init("tornado-" + pool.currency + "-" + pool.denomination + "-" + String(pool.chainID) + "-0x" + Data.secureRandom(count: 62).hexString)
    }
}
public struct PrivacyProof: Decodable, Sendable {
    public let commitment: String
    public let nullifierHash: String
    public let root: String
    public let proof: String
    public let publicSignals: [String]
}
public struct PrivacyTransactionIntent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case deposit, withdraw }
    public let kind: Kind
    public let noteID: UUID
    public let poolID: String
    public let recipient: String
    public let commitment: String
    public let root: String?
    public let nullifierHash: String?
    public let fee: BigUInt
}
