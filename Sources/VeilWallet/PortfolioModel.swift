import Foundation
import WalletCore
import BigInt

@MainActor extension AppModel {
    var preferences: WalletPreferences { local.preferences ?? WalletPreferences() }
    var assetQueries: [AssetQuery] {
        guard let wallet else { return [] }
        return PortfolioPlanner.queries(wallet: wallet, chains: local.chains, customTokens: local.tokens, scope: .all, selectedChain: chainID, selectedProfile: profileID)
    }
    var discoveryQueries: [AssetQuery] {
        guard let wallet else { return [] }
        return PortfolioPlanner.queries(wallet: wallet, chains: local.chains, customTokens: local.tokens, scope: preferences.scanScope, selectedChain: chainID, selectedProfile: profileID)
    }
    var assetRefreshKey: String {
        [String(unlocked), String(networkSessionReady), String(busy), walletID?.uuidString ?? "", String(chainID), profileID, String(preferences.autoRefreshAssets), preferences.scanScope.rawValue, String(preferences.refreshMinutes), String(local.chains.hashValue), local.tokens.map { $0.id + ":" + String($0.decimals) }.joined(separator: ",")].joined(separator: "|")
    }
    func snapshot(_ query: AssetQuery) -> AssetBalanceSnapshot? { local.assetBalances?.first { $0.matches(query) } }
    func restoreSelectedBalances() {
        guard let wallet, let account else { return }
        let assets: [Token?] = [nil] + tokens.map(Optional.some)
        for token in assets {
            let query = AssetQuery(walletID: wallet.id, chain: chain, account: account, token: token)
            if let record = snapshot(query), let value = record.balance { balances[token?.id ?? "native"] = value; balancesUpdated = min(balancesUpdated ?? record.updatedAt ?? .distantPast, record.updatedAt ?? .distantPast) }
        }
    }
    func setPreferences(_ update: (inout WalletPreferences) -> Void) async {
        guard unlocked else { return }
        let operation = epoch, previous = local.preferences
        var value = preferences; update(&value); local.preferences = value
        do { try await saveLocal(); if operation == epoch { checkAutoLock() } }
        catch { if operation == epoch { if local.preferences == value { local.preferences = previous }; self.error = error.localizedDescription } }
    }
    func runAutomaticAssetRefresh() async {
        guard preferences.autoRefreshAssets else { return }
        while !Task.isCancelled, networkSessionReady {
            while discovering, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            if !busy { await refreshPortfolio(force: false) }
            do { try await Task.sleep(for: .seconds(preferences.refreshInterval)) } catch { return }
        }
    }
    func refreshPortfolio(force: Bool = true, selectedOnly: Bool = false) async {
        guard networkSessionReady, !busy, !discovering, let walletID else { return }
        let operation = epoch, run = UUID(), queries = (selectedOnly ? assetQueries : discoveryQueries).filter { $0.automatic && (!selectedOnly || ($0.chain.id == chainID && $0.account.profileID == account?.profileID)) }
        let client = PortfolioClient(transport: TorTransport(gate: gate), isolation: isolationKey + ":assets")
        let jobs = queries.filter { query in
            guard !force, let value = snapshot(query) else { return true }
            let ttl: TimeInterval = value.error == nil ? preferences.refreshInterval : 30
            return Date().timeIntervalSince(value.attemptedAt) >= ttl
        }
        guard !jobs.isEmpty else { restoreSelectedBalances(); return }
        discovering = true; discoveryRun = run; discoveryCompleted = 0; discoveryTotal = jobs.count
        defer { if discoveryRun == run { discovering = false; discoveryRun = nil; checkingAssets = [] } }
        await withTaskGroup(of: (AssetQuery, BigUInt?, String?).self) { group in
            var next = 0
            @MainActor func submit(_ query: AssetQuery) {
                checkingAssets.insert(query.id)
                group.addTask {
                    do { return (query, try await client.balance(query), nil) }
                    catch { return (query, nil, error.localizedDescription) }
                }
            }
            // Keep enough Tor capacity free for transaction / lock operations.
            for _ in 0..<min(3, jobs.count) { submit(jobs[next]); next += 1 }
            while let (query, balance, error) = await group.next() {
                guard !Task.isCancelled, epoch == operation, networkSessionReady, self.walletID == walletID, !busy else { group.cancelAll(); break }
                let value = AssetBalanceSnapshot(query: query, balance: balance, error: error, previous: snapshot(query))
                var records = local.assetBalances ?? []
                records.removeAll { $0.id == query.id }; records.append(value)
                local.assetBalances = Array(records.suffix(5000)); discoveryCompleted += 1; checkingAssets.remove(query.id)
                if query.chain.id == chainID, query.account.profileID == account?.profileID, let balance {
                    balances[query.token?.id ?? "native"] = balance; balancesUpdated = value.updatedAt
                }
                if next < jobs.count { submit(jobs[next]); next += 1 }
            }
        }
        guard operation == epoch, unlocked else { return }
        do { try await saveLocal() } catch { if operation == epoch { self.error = error.localizedDescription } }
    }
    func openAsset(_ query: AssetQuery, action: Sheet? = nil) {
        guard !busy, walletID == query.walletID else { return }
        chainID = query.chain.id; profileID = query.account.profileID; selectionChanged()
        if action == .send { transferDraft = TransferDraft(recipient: "", amount: "", assetID: query.token?.id ?? "native") }
        sheet = action
    }
    func fundedAssets(for account: WalletAccount) -> [AssetBalanceSnapshot] {
        (local.assetBalances ?? []).filter { $0.walletID == walletID && $0.profileID == account.profileID && $0.sender == account.networkAddress && ($0.balance ?? 0) > 0 }
    }
    func cacheSelectedBalances(_ values: [String: BigUInt]) {
        guard let walletID, let account else { return }
        var records = local.assetBalances ?? []
        for token in [Token?](arrayLiteral: nil) + tokens.map(Optional.some) {
            guard let amount = values[token?.id ?? "native"] else { continue }
            let query = AssetQuery(walletID: walletID, chain: chain, account: account, token: token)
            records.removeAll { $0.id == query.id }; records.append(.init(query: query, balance: amount))
        }
        local.assetBalances = Array(records.suffix(5000))
    }
}
