import Foundation

public enum DexProtocol: String, Codable, Sendable { case v2, v2Avax, v3, v3Router02, algebra, solidly, slipstream, liquidityBook, curve, curveETH, balancerV2, balancerV3, uniswapV4 }
public struct DexVenue: Identifiable, Codable, Equatable, Sendable {
    public let id: String; public let name: String; public let chainID: UInt64; public let `protocol`: DexProtocol
    public let router: String; public let factory: String?; public let quoter: String?; public let wrapped: String?; public let source: String
    public var usesPoolID: Bool { [.balancerV2, .balancerV3].contains(`protocol`) }
    public var usesPermit2: Bool { [.balancerV3, .uniswapV4].contains(`protocol`) }
    public var usesFee: Bool { [.v3, .v3Router02, .slipstream, .liquidityBook, .uniswapV4].contains(`protocol`) }
    public var defaultFee: UInt32 { 0 }
    public var feeLabel: String { `protocol` == .slipstream ? "Tick spacing" : (`protocol` == .liquidityBook ? "Bin step" : L("message.pool_fee_parts_per_million")) }
}
public enum DexCatalog {
    public static let additional: [DexVenue] = {
        guard let url = Bundle.module.url(forResource: "dex-venues", withExtension: "json"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([DexVenue].self, from: data) else { return [] }
        return values
    }()
    public static var all: [DexVenue] {
        let original = DexClient.deployments.map { chain, value in
            DexVenue(id: "uniswap-v2-" + String(chain), name: "Uniswap V2", chainID: chain, protocol: .v2, router: value.router, factory: value.factory, quoter: nil, wrapped: nil, source: "https://github.com/Uniswap/docs/blob/main/content/protocols/v2/deployments.mdx")
        }
        return (original + additional).sorted { $0.name < $1.name }
    }
    public static func on(_ chainID: UInt64) -> [DexVenue] { all.filter { $0.chainID == chainID } }
    public static func find(_ id: String) -> DexVenue? { all.first { $0.id == id } }
}
