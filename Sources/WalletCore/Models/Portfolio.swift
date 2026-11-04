import Foundation
import BigInt

public struct AssetQuery: Identifiable, Sendable {
    public let walletID: UUID
    public let chain: Chain
    public let account: WalletAccount
    public let token: Token?
    public init(walletID: UUID, chain: Chain, account: WalletAccount, token: Token? = nil) { self.walletID = walletID; self.chain = chain; self.account = account; self.token = token }
    public var id: String { walletID.uuidString + ":" + String(chain.id) + ":" + account.profileID + ":" + (token?.id ?? "native") }
    public var symbol: String { token?.symbol ?? chain.symbol }
    public var decimals: Int { token?.decimals ?? chain.decimals }
    public var automatic: Bool { chain.configured && chain.family != .monero && chain.family != .nostr && chain.profileKeys.contains(account.profileID) && account.isBound && account.supportsPublicBalanceQuery && (token == nil || token?.chainID == chain.id) }
}
public struct AssetBalanceSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let walletID: UUID
    public let chainID: UInt64
    public let profileID: String
    public let sender: String
    public let tokenID: String?
    public let endpoint: String
    public let decimals: Int
    public var amount: String?
    public var updatedAt: Date?
    public var attemptedAt: Date
    public var error: String?
    public var balance: BigUInt? { amount.flatMap { BigUInt($0) } }
    public init(query: AssetQuery, balance: BigUInt?, error: String? = nil, previous: AssetBalanceSnapshot? = nil) {
        id = query.id; walletID = query.walletID; chainID = query.chain.id; profileID = query.account.profileID; sender = query.account.networkAddress; tokenID = query.token?.id; endpoint = query.chain.rpcURL; decimals = query.decimals; attemptedAt = Date(); self.error = error
        let validPrevious = previous?.matches(query) == true ? previous : nil
        amount = balance.map(String.init) ?? validPrevious?.amount; updatedAt = balance == nil ? validPrevious?.updatedAt : attemptedAt
    }
    public func matches(_ query: AssetQuery) -> Bool { id == query.id && sender == query.account.networkAddress && endpoint == query.chain.rpcURL && tokenID == query.token?.id && decimals == query.decimals }
}
public enum PortfolioPlanner {
    public static let commonEVM: Set<UInt64> = [1, 56, 137, 42161, 10, 8453, 43114, 324, 59144, 534352, 5000, 100, 80094, 146, 999, 196]
    public static func queries(wallet: WalletSummary, chains: [Chain], customTokens: [Token], scope: AssetScanScope, selectedChain: UInt64, selectedProfile: String) -> [AssetQuery] {
        let tokens = TokenCatalog.merged(with: customTokens)
        var result: [AssetQuery] = []
        for chain in chains where chain.canQuery && chain.family != .nostr && (chain.id == selectedChain || scope == .all || (scope == .common && !chain.isTestnet && (!chain.isEVM || commonEVM.contains(chain.id)))) {
            let accounts = wallet.accounts(on: chain).sorted { ($0.profileID == selectedProfile ? 0 : 1) < ($1.profileID == selectedProfile ? 0 : 1) }
            var addresses = Set<String>()
            for account in accounts where account.isBound {
                let canonical = chain.family == .litecoin ? ((try? Litecoin.addressInfo(account.networkAddress).canonicalAddress) ?? account.networkAddress) : account.networkAddress
                guard addresses.insert(canonical).inserted else { continue }
                result.append(.init(walletID: wallet.id, chain: chain, account: account))
                if chain.isEVM || chain.family == .tron {
                    result += tokens.filter { $0.chainID == chain.id }.map { .init(walletID: wallet.id, chain: chain, account: account, token: $0) }
                }
            }
        }
        return result.sorted { lhs, rhs in
            let a = lhs.chain.id == selectedChain ? 0 : 1, b = rhs.chain.id == selectedChain ? 0 : 1
            if a != b { return a < b }
            if lhs.chain.id != rhs.chain.id { return EVMNetworkSupport.rank(lhs.chain) == EVMNetworkSupport.rank(rhs.chain) ? lhs.chain.name < rhs.chain.name : EVMNetworkSupport.rank(lhs.chain) < EVMNetworkSupport.rank(rhs.chain) }
            if lhs.account.profileID != rhs.account.profileID { return lhs.account.profileID < rhs.account.profileID }
            return lhs.token == nil && rhs.token != nil
        }
    }
}
