import Foundation

public struct TokenPreset: Codable, Identifiable, Sendable {
    public let chainID: UInt64
    public let contract: String
    public let symbol: String
    public let name: String
    public let decimals: Int
    public let logo: String
    public let provenance: String
    public let source: String
    public var token: Token { try! Token(chainID: chainID, contract: contract, symbol: symbol, decimals: decimals) }
    public var id: String { token.id }
}
public enum TokenCatalog {
    public static let all: [TokenPreset] = {
        guard let url = Bundle.module.url(forResource: "token-presets", withExtension: "json"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([TokenPreset].self, from: data) else { return [] }
        guard values.allSatisfy({ (try? Token(chainID: $0.chainID, contract: $0.contract, symbol: $0.symbol, decimals: $0.decimals)) != nil }), Set(values.map(\.id)).count == values.count else { return [] }
        return values
    }()
    public static func preset(for token: Token) -> TokenPreset? { all.first { $0.id == token.id } }
    public static func merged(with custom: [Token]) -> [Token] {
        var result = all.map(\.token), ids = Set(result.map(\.id))
        for token in custom where ids.insert(token.id).inserted { result.append(token) }
        return result
    }
}
