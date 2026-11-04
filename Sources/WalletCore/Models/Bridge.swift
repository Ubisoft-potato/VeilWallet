import Foundation
import BigInt

public enum BridgeProtocol: String, Codable, CaseIterable, Sendable {
    case allbridgeOFT, stargateV2
    public var name: String { self == .allbridgeOFT ? "Allbridge OFT · ETH / TRON" : "Stargate V2 · ETH / BSC" }
}
public struct BridgeDeployment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let networkID: UInt64
    public let protocolID: UInt32
    public let endpointID: UInt32
    public let bridgeProtocol: BridgeProtocol
    public let contract: String
    public let tokenAddress: String
    public let decimals: Int
    public let source: String
    public var token: Token { get throws { try Token(chainID: networkID, contract: tokenAddress, symbol: "USDT", decimals: decimals) } }
}
public enum BridgeCatalog {
    public static let deployments: [BridgeDeployment] = [
        .init(id: "allbridge-oft-eth", networkID: 1, protocolID: 1, endpointID: 30101, bridgeProtocol: .allbridgeOFT, contract: "0xeC455fFC19811e573eb5700a1bDff6ee1C47AB7B", tokenAddress: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6, source: "https://api.core.allbridge.io/token-info?filter=all"),
        .init(id: "allbridge-oft-tron", networkID: TronAddress.chainID, protocolID: 3, endpointID: 30420, bridgeProtocol: .allbridgeOFT, contract: "TWPziSAroSacAjDuL52ByQzU86s9mP2gPr", tokenAddress: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", decimals: 6, source: "https://api.core.allbridge.io/token-info?filter=all"),
        .init(id: "stargate-usdt-eth", networkID: 1, protocolID: 30101, endpointID: 30101, bridgeProtocol: .stargateV2, contract: "0x933597a323Eb81cAe705C5bC29985172fd5A3973", tokenAddress: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6, source: "https://github.com/stargate-protocol/stargate-v2/blob/main/packages/stg-evm-v2/deployments/ethereum-mainnet/StargatePoolUSDT.json"),
        .init(id: "stargate-usdt-bsc", networkID: 56, protocolID: 30102, endpointID: 30102, bridgeProtocol: .stargateV2, contract: "0x138EB30f73BC423c6455C53df6D89CB01d9eBc63", tokenAddress: "0x55d398326f99059fF775485246999027B3197955", decimals: 18, source: "https://github.com/stargate-protocol/stargate-v2/blob/main/packages/stg-evm-v2/deployments/bsc-mainnet/StargatePoolUSDT.json")
    ]
    public static func find(_ id: String) -> BridgeDeployment? { deployments.first { $0.id == id } }
    public static func on(_ network: UInt64) -> [BridgeDeployment] { deployments.filter { $0.networkID == network } }
    public static func destinations(for source: BridgeDeployment) -> [BridgeDeployment] { deployments.filter { $0.bridgeProtocol == source.bridgeProtocol && $0.networkID != source.networkID } }
}
public struct BridgeQuote: Codable, Sendable {
    public let source: BridgeDeployment
    public let destination: BridgeDeployment
    public let sender: String
    public let recipient: String
    public let amount: BigUInt
    public let expectedDestination: BigUInt
    public let minimumDestination: BigUInt
    public let nativeFee: BigUInt
    public let adminFeeBP: UInt32
    public let slippageBP: UInt32
    public let sourceOFT: String
    public let destinationOFT: String
    public let sendAmount: BigUInt
    public let minimumLD: BigUInt
    public let quotedAt: Date
    public var isExpired: Bool { Date().timeIntervalSince(quotedAt) > 90 }
    public var absoluteMinimumEnforced: Bool { source.bridgeProtocol == .stargateV2 }
    public var record: BridgeTransferRecord {
        .init(sourceID: source.id, destinationID: destination.id, sender: sender, recipient: recipient, sourceOFT: sourceOFT, destinationOFT: destinationOFT, amount: String(amount), minimumDestination: String(minimumDestination))
    }
}
public enum BridgeTransactionPlan: Sendable { case evm(TransactionPreview), tron(NativeTransferPlan) }
public struct BridgeTransferRecord: Codable, Sendable {
    public let sourceID: String
    public let destinationID: String
    public let sender: String
    public let recipient: String
    public let sourceOFT: String
    public let destinationOFT: String
    public let amount: String
    public let minimumDestination: String
    public var guid: String?
    public var destinationHash: String?
    public var destinationVerified: Bool?
    public init(sourceID: String, destinationID: String, sender: String, recipient: String, sourceOFT: String, destinationOFT: String, amount: String, minimumDestination: String) {
        self.sourceID = sourceID; self.destinationID = destinationID; self.sender = sender; self.recipient = recipient
        self.sourceOFT = sourceOFT; self.destinationOFT = destinationOFT; self.amount = amount; self.minimumDestination = minimumDestination
    }
}
