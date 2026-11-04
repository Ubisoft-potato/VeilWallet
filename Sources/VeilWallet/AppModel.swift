import Foundation
import SwiftUI
import AppKit
import Combine
import WalletCore
import BigInt

@MainActor final class AppModel: ObservableObject {
    let vault: VaultStore
    let store: LocalStore
    let gate: NetworkGate
    let tor: TorController
    let monero: MoneroRuntime
    let proofRuntime: PrivacyProofRuntime
    let sessionLease = WalletSessionLease()
    @Published var privacyNotes: [PrivacyNoteSummary] = []
    @Published var unlocked = false
    @Published var hasVault = false
    @Published private(set) var authenticating = false
    @Published var wallets: [WalletSummary] = []
    @Published var walletID: UUID?
    @Published var local = LocalStore.State()
    @Published var profileID = "evm"
    @Published var chainID: UInt64 = 1
    @Published var balances: [String: BigUInt] = [:]
    @Published var balancesUpdated: Date?
    @Published var route: Route = .assets
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var sheet: Sheet?
    @Published var transferDraft: TransferDraft?
    @Published var discovering = false
    @Published var discoveryCompleted = 0
    @Published var discoveryTotal = 0
    @Published var checkingAssets: Set<String> = []
    var discoveryRun: UUID?
    @Published var fetchingPrices = false
    @Published var priceRefreshError: String?
    var priceRun: UUID?
    @Published var bridges = ""
    private var timer: AnyCancellable?
    private var torObservation: AnyCancellable?
    private var moneroObservation: AnyCancellable?
    private var eventMonitor: Any?
    private var lastInteraction = ContinuousClock.now
    private(set) var epoch = UUID()
    private var sessionID = UUID().uuidString
    private var sessionReady = false
    var wallet: WalletSummary? { wallets.first { $0.id == walletID } }
    var chain: Chain { local.chains.first { $0.id == chainID } ?? Chain.defaults[0] }
    var availableAccounts: [WalletAccount] { wallet?.accounts(on: chain) ?? [] }
    var account: WalletAccount? { availableAccounts.first { $0.profileID == profileID } ?? availableAccounts.first }
    var canQueryBalance: Bool { chain.canQuery && account?.isBound == true && (chain.family == .monero ? wallet?.canSign == true : account?.supportsPublicBalanceQuery == true) }
    var address: String? { account?.networkAddress }
    var compatibleChains: [Chain] { guard let wallet else { return local.chains }; return local.chains.filter { !wallet.accounts(on: $0).isEmpty }.sorted { EVMNetworkSupport.rank($0) < EVMNetworkSupport.rank($1) } }
    var tokens: [Token] { guard chain.isEVM || chain.family == .tron else { return [] }; return TokenCatalog.merged(with: local.tokens).filter { $0.chainID == chainID } }
    var activities: [Activity] { local.activities.filter { $0.chainID == chainID && ($0.walletID == walletID || ($0.transaction?.sender == address && address != nil)) }.sorted { $0.date > $1.date } }
    var networkSessionReady: Bool { unlocked && sessionReady && gate.isReady }
    var ready: Bool { networkSessionReady && !busy }
    var canSendCurrentAccount: Bool { guard let account else { return false }; if chain.family == .monero { return wallet?.canSign == true && monero.walletID == walletID && monero.balance != nil }; return chain.isEVM ? chain.canTransfer : NativeTransferPlan.supports(account: account, chain: chain) }
    var moneroRestoreHeight: UInt64 { walletID.flatMap { local.moneroRestoreHeights?[$0.uuidString] } ?? 0 }
    init(previewMode: Bool = false) {
        let dir = VaultStore.defaultDirectory
        vault = VaultStore(url: dir.appendingPathComponent("vault.json"))
        store = LocalStore(url: dir.appendingPathComponent("local.sealed"))
        let gate = NetworkGate(); self.gate = gate
        var bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TorRuntime.bundle", isDirectory: true)
        #if DEBUG
        if !FileManager.default.fileExists(atPath: bundle.path) {
            bundle = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/Tor")
        }
        #endif
        tor = TorController(gate: gate, bundle: bundle, dataDirectory: dir.appendingPathComponent("Tor"))
        var moneroExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MoneroRuntime.bundle/Contents/MacOS/monero-wallet-rpc")
        #if DEBUG
        if !FileManager.default.fileExists(atPath: moneroExecutable.path) { moneroExecutable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/Monero/monero-wallet-rpc") }
        #endif
        monero = MoneroRuntime(executable: moneroExecutable, directory: dir.appendingPathComponent("Monero"), gate: gate)
        var proofDirectory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PrivacyRuntime.bundle")
        #if DEBUG
        if !FileManager.default.fileExists(atPath: proofDirectory.path) { proofDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/PrivacyRuntime") }
        #endif
        proofRuntime = PrivacyProofRuntime(directory: proofDirectory)
        #if DEBUG
        if previewMode {
            let example = WalletSummary(name: L("message.ui_preview_watch_only_wallet"), address: "0x000000000000000000000000000000000000dEaD", kind: .watch)
            wallets = [example]; walletID = example.id; unlocked = true
            return
        }
        #endif
        torObservation = tor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send(); Task { @MainActor in if let self, !self.gate.isReady { self.monero.stop() } } }
        moneroObservation = monero.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Task { hasVault = await vault.exists() }
        timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.checkAutoLock() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            self?.recordInteraction(); return event
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }
    func authenticate(password: String, create: Bool) async throws {
        let operation = epoch
        guard !busy, !authenticating else { throw WalletError.invalid(L("message.the_previous_unlock_is_still_running_please_wait")) }; busy = true; authenticating = true
        defer { authenticating = false; if operation == epoch { busy = false } }
        try sessionLease.acquire(directory: VaultStore.defaultDirectory)
        if create { try await vault.create(password: password); hasVault = true }
        let records = try await vault.unlock(password: password)
        guard operation == epoch else { await vault.lock(); return }
        do { local = try await store.load(); local.activities = try await store.recoverTransactions(into: local.activities) }
        catch { await vault.lock(); throw error }
        guard operation == epoch else { await vault.lock(); return }
        wallets = records; walletID = records.first?.id; hasVault = true; selectionChanged()
        unlocked = true; sessionReady = true; lastInteraction = .now
        privacyNotes = try await vault.privacyNotes()
        guard operation == epoch else { return }
        tor.start(bridges: bridgeLines)
        if records.isEmpty { sheet = .addWallet }
    }
    private var idleSeconds: TimeInterval {
        let duration = lastInteraction.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    func checkAutoLock() { if unlocked, preferences.shouldLock(idleSeconds: idleSeconds) { lock() } }
    func recordInteraction() { checkAutoLock(); lastInteraction = .now }
    func lock() {
        guard unlocked || busy else { return }
        epoch = UUID(); unlocked = false; sessionReady = false; sheet = nil
        walletID = nil; wallets = []; privacyNotes = []; balances = [:]; balancesUpdated = nil; local = .init(); transferDraft = nil
        notice = nil; error = nil; busy = false; sessionID = UUID().uuidString
        discoveryRun = nil; discovering = false; checkingAssets = []; discoveryCompleted = 0; discoveryTotal = 0
        priceRun = nil; fetchingPrices = false; priceRefreshError = nil
        tor.stop()
        monero.stop()
        proofRuntime.stopImmediately()
        // Serialize cleanup before any subsequent authentication can complete.
        Task { await vault.lock() }
    }
    var bridgeLines: [String] { bridges.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func restartTor() { tor.stop(); monero.stop(); sessionID = UUID().uuidString; tor.start(bridges: bridgeLines) }
    func client(chain: Chain? = nil, wallet: WalletSummary? = nil) -> RPCClient {
        let chain = chain ?? self.chain; let wallet = wallet ?? self.wallet
        return RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: sessionID + ":" + (wallet?.id.uuidString ?? "none") + ":" + String(chain.id), noncePolicy: EVMNoncePolicy(activities: local.activities))
    }
    func refresh() async {
        guard ready, canQueryBalance, let wallet, let account else { return }
        if chain.family != .monero { await refreshPortfolio(selectedOnly: true); return }
        let operation = epoch; let chain = chain; let client = client(); let tokens = tokens
        busy = true; defer { if operation == epoch { busy = false } }
        do {
            var result: [String: BigUInt]
            if chain.family == .monero {
                try await vault.openMonero(runtime: monero, walletID: wallet.id, node: chain.rpcURL, restoreHeight: moneroRestoreHeight)
                let balance = try await monero.synchronize(); result = ["native": balance.total]
            } else if chain.isEVM {
                try await client.verifyChain()
                result = ["native": try await client.balance(address: account.networkAddress)]
                for token in tokens { result[token.id] = try await client.balance(address: account.networkAddress, token: token) }
            } else {
                result = ["native": try await NativeBalanceClient(transport: TorTransport(gate: gate), chain: chain, isolation: isolationKey).balance(account: account)]
                if chain.family == .tron {
                    let tron = TronContractClient(transport: TorTransport(gate: gate), chain: chain, isolation: isolationKey)
                    for token in tokens { result[token.id] = try await tron.balance(address: account.networkAddress, token: token) }
                }
            }
            guard operation == epoch, self.walletID == wallet.id, chain.id == self.chainID, self.account?.profileID == account.profileID else { return }
            balances = result; balancesUpdated = Date()
            cacheSelectedBalances(result); try await saveLocal()
        } catch { if operation == epoch { self.error = error.localizedDescription } }
    }
    func selectionChanged() {
        if chain.family != .monero || monero.walletID != walletID { monero.stop() }
        balances = [:]; balancesUpdated = nil; notice = nil
        if let wallet, wallet.accounts(on: chain).isEmpty, let candidate = local.chains.first(where: { !wallet.accounts(on: $0).isEmpty }) { chainID = candidate.id }
        if !availableAccounts.contains(where: { $0.profileID == profileID }) { profileID = availableAccounts.first?.profileID ?? "" }
        restoreSelectedBalances()
    }
    var isolationKey: String { sessionID + ":" + (walletID?.uuidString ?? "none") + ":" + String(chainID) }
    func reloadWallets() async throws { wallets = try await vault.summaries(); selectionChanged() }
    func addWallet(name: String, kind: WalletKind, material: String, passphrase: String, account: UInt32, profileID: String = "evm", overrides: [String: String] = [:]) async throws {
        let operation = epoch
        let record: WalletSummary
        switch kind {
        case .mnemonic: record = try await vault.addMnemonic(name: name, phrase: material, passphrase: passphrase, account: account, overrides: overrides)
        case .privateKey: record = try await vault.addPrivateKey(name: name, material: material, profileID: profileID)
        case .watch: record = try await vault.addWatch(name: name, address: material, profileID: profileID)
        }
        guard operation == epoch, unlocked else { return }
        wallets = try await vault.summaries(); walletID = record.id; selectionChanged()
    }
    func saveLocal() async throws { guard unlocked else { throw WalletError.locked }; try await store.save(local) }
    func send(preview: TransactionPreview, password: String) async throws -> String {
        guard ready, chain.canTransfer, let wallet, wallet.canSign, account?.networkAddress == preview.sender else { throw WalletError.locked }
        let operation = epoch; let client = client(); let chain = chain
        busy = true; defer { if operation == epoch { busy = false } }
        let privacy = try await privacySource(for: preview)
        if let privacy {
            if let ref = preview.replacement { try await vault.authorizePrivacyRetry(privacy, hash: ref.hash, password: password) }
            else { try await vault.authorizePrivacy(privacy, password: password) }
        }
        try ensureFreshReplacement(preview)
        try ensureLegacyHistoryManaged()
        try await client.revalidate(preview)
        let raw = try await vault.sign(transaction: preview.transaction, walletID: wallet.id, password: password)
        guard operation == epoch, unlocked, gate.isReady, !preview.isExpired else { throw WalletError.networkBlocked }
        let hash = "0x" + raw.keccak256.hexString
        guard !local.activities.contains(where: { $0.chainID == chain.id && $0.hash == hash }) else { throw WalletError.invalid(L("message.this_signed_transaction_hash_already_exists_refresh_its_existing_record")) }
        var activity = Activity(walletID: wallet.id, chainID: chain.id, hash: hash, to: preview.recipient, amount: preview.amount, symbol: preview.symbol)
        activity.operation = preview.purpose.invocation == nil ? nil : preview.purpose.title
        if case .bridge(let quote, _) = preview.purpose { activity.bridge = quote.record }
        if let privacy { activity.privacyNoteID = privacy.noteID; activity.privacyKind = privacy.kind.rawValue }
        let action = preview.replacement?.action ?? .original
        activity.transaction = .evm(preview, groupID: preview.replacement?.groupID ?? activity.id, action: action, parentID: preview.replacement?.activityID)
        if action != .original { activity.operation = action.label + " · " + preview.purpose.title }
        activity.status = activity.statusLabel
        var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, preview: preview, raw: raw); archive.activity = activity
        // Both raw bytes and their immutable intent reach local encrypted storage
        // before a node can see them. Startup recovers a partial journal commit.
        try await store.saveTransaction(archive)
        if let privacy {
            if let ref = preview.replacement { try await vault.recordPrivacyReplacement(privacy, originalHash: ref.hash, newHash: hash, cancellation: action == .cancel, password: password) }
            else { try await vault.recordPrivacyTransaction(privacy, hash: hash, password: password) }
            privacyNotes = try await vault.privacyNotes()
        }
        guard operation == epoch, unlocked else { throw WalletError.locked }
        local.activities.append(activity); try await saveLocal()
        guard operation == epoch, networkSessionReady, !preview.isExpired, wallet.id == walletID, chain.id == chainID, account?.networkAddress == preview.sender else { throw WalletError.networkBlocked }
        let state = try await client.nonceState(sender: preview.sender)
        if state.pending < preview.transaction.nonce {
            notice = L("message.the_transaction_is_encrypted_in_the_local_queue_an_earlier")
            return hash
        }
        guard state.latest <= preview.transaction.nonce, preview.replacement != nil || state.pending == preview.transaction.nonce else { throw WalletError.invalid(L("message.the_sequence_changed_the_transaction_remains_in_the_local_queue")) }
        try await markBroadcast(activity.id, operation: operation)
        do {
            let returnedHash = try await client.broadcast(raw)
            guard operation == epoch else { return returnedHash }
            updateTransaction(activity.id, phase: .submitted)
            try await saveLocal()
            return returnedHash
        } catch {
            if operation == epoch { notice = L("message.submission_is_unverified_look_up_the_saved_local_hash_in", hash) }
            throw error
        }
    }
    func checkReceipt(_ activity: Activity) async {
        guard ready else { return }
        let operation = epoch; busy = true; defer { if operation == epoch { busy = false } }
        do {
            if chain.isEVM { try await refreshEVMGroup(activity, operation: operation); return }
            if [.bitcoin, .litecoin].contains(chain.family) { try await refreshUTXOGroup(activity, operation: operation) }
            else { try await refreshNativeActivity(activity, operation: operation) }
        } catch { if operation == epoch { self.error = error.localizedDescription } }
    }
    func copyAddress(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        let change = NSPasteboard.general.changeCount
        Task {
            try? await Task.sleep(for: .seconds(30))
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
    }
    func prepareNative(recipient: String, amount: String, memo: String = "", gasPrice: String? = nil) async throws -> NativeTransferPlan {
        guard ready, let wallet, let account, canSendCurrentAccount else { throw WalletError.locked }
        try ensureNativeAccountAvailable()
        let publicKey = [.aptos, .cosmos].contains(chain.family) ? try await vault.signingPublicKey(walletID: wallet.id, profileID: account.profileID) : nil
        return try await nativeClient().prepare(account: account, recipient: recipient, amount: amount, publicKey: publicKey, memo: memo, gasPrice: gasPrice)
    }
    func prepareMonero(recipient: String, amount: String, password: String) async throws -> MoneroProposal {
        guard ready, let walletID, chain.family == .monero, canSendCurrentAccount else { throw WalletError.invalid(L("message.finish_scanning_this_xmr_wallet_locally_first")) }
        try ensureNativeAccountAvailable()
        return try await vault.prepareMonero(runtime: monero, walletID: walletID, recipient: recipient, amount: amount, password: password)
    }
    func broadcastMonero(proposal: MoneroProposal, password: String) async throws -> String {
        guard ready, chain.family == .monero, proposal.walletID == walletID, proposal.sender == address, !proposal.isExpired else { throw WalletError.invalid(L("message.the_xmr_preview_does_not_match_the_current_account")) }
        let operation = epoch; let chainID = chainID; busy = true; defer { if operation == epoch { busy = false } }
        try ensureNativeAccountAvailable()
        try await vault.authorizeMoneroBroadcast(proposal, password: password)
        guard operation == epoch, gate.isReady, monero.walletID == walletID else { throw WalletError.networkBlocked }
        var activity = Activity(walletID: proposal.walletID, chainID: chainID, hash: proposal.hash, to: proposal.recipient, amount: Ethereum.formatUnits(proposal.amount, decimals: 12, precision: 12), symbol: "XMR")
        activity.transaction = TransactionRecord(groupID: activity.id, sender: proposal.sender, profileID: account?.profileID ?? "monero", sequence: nil, nativeCost: proposal.amount + proposal.fee)
        activity.status = activity.statusLabel
        var archive = try TransactionArchive(activityID: activity.id, chainID: chainID, profileID: account?.profileID ?? "monero", proposal: proposal); archive.activity = activity
        try await store.saveTransaction(archive)
        guard operation == epoch, unlocked else { throw WalletError.locked }
        local.activities.append(activity); try await saveLocal()
        guard operation == epoch, networkSessionReady, !proposal.isExpired, proposal.walletID == walletID, proposal.sender == address else { throw WalletError.networkBlocked }
        try await markBroadcast(activity.id, operation: operation)
        do {
            let hash = try await monero.broadcast(proposal)
            guard operation == epoch else { return hash }
            updateTransaction(activity.id, phase: .submitted); try await saveLocal(); return hash
        } catch { if operation == epoch { notice = L("message.xmr_broadcast_is_unverified_sync_the_local_wallet_and_check") }; throw error }
    }
    func sendNative(plan: NativeTransferPlan, password: String) async throws -> String {
        guard ready, let wallet, let account, wallet.canSign, canSendCurrentAccount else { throw WalletError.locked }
        try ensureNativeAccountAvailable()
        let operation = epoch; let chain = chain; busy = true; defer { if operation == epoch { busy = false } }
        let client = nativeClient()
        try await client.revalidate(plan, account: account)
        guard Set(plan.spentOutputs).isDisjoint(with: reservedUTXOInputs) else { throw WalletError.invalid(L("message.another_local_transaction_reserved_an_input_in_this_preview_select")) }
        let signed = try await vault.signNative(plan: plan, walletID: wallet.id, password: password)
        guard !local.activities.contains(where: { $0.chainID == chain.id && $0.hash == signed.hash }) else { throw WalletError.invalid(L("message.this_signed_hash_already_exists_verify_its_original_transaction_a")) }
        guard operation == epoch, unlocked, gate.isReady, !plan.isExpired else { throw WalletError.networkBlocked }
        var activity = Activity(walletID: wallet.id, chainID: chain.id, hash: signed.hash, to: plan.recipient, amount: Ethereum.formatUnits(plan.amount, decimals: chain.decimals, precision: chain.decimals), symbol: chain.symbol)
        if let quote = plan.bridge { activity.operation = L("message.bridge_b3c670d7"); activity.bridge = quote.record }
        else if plan.swap != nil { activity.operation = L("message.tron_dex_swap") } else if plan.contract != nil { activity.operation = L("message.tron_contract_call_approval") }
        activity.transaction = .native(plan, groupID: activity.id); activity.status = activity.statusLabel
        var archive = try TransactionArchive(activityID: activity.id, walletID: wallet.id, plan: plan, signed: signed); archive.activity = activity
        try await store.saveTransaction(archive)
        guard operation == epoch, unlocked else { throw WalletError.locked }
        local.activities.append(activity); try await saveLocal()
        guard operation == epoch, networkSessionReady, !plan.isExpired, wallet.id == walletID, chain.id == chainID, self.account?.networkAddress == plan.sender else { throw WalletError.networkBlocked }
        try await markBroadcast(activity.id, operation: operation)
        do {
            let hash = try await client.broadcast(signed)
            guard operation == epoch else { return hash }
            updateTransaction(activity.id, phase: .submitted); try await saveLocal(); return hash
        } catch {
            if operation == epoch { notice = L("message.submission_is_unverified_check_the_saved_local_hash_to_avoid") }; throw error
        }
    }
}
enum Route: String, CaseIterable, Identifiable {
    case assets, accounts, networks, activity, discover, privacy, settings
    var title: String {
        switch self {
        case .assets: return L("navigation.assets")
        case .accounts: return L("navigation.accounts")
        case .networks: return L("navigation.networks")
        case .activity: return L("navigation.transactions")
        case .discover: return L("navigation.discover")
        case .privacy: return L("navigation.privacy")
        case .settings: return L("navigation.settings")
        }
    }
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .accounts: return "key.horizontal"
        case .networks: return "point.3.connected.trianglepath.dotted"
        case .assets: return "square.stack.3d.up"
        case .activity: return "clock.arrow.circlepath"
        case .discover: return "safari"
        case .privacy: return "network.badge.shield.half.filled"
        case .settings: return "slider.horizontal.3"
        }
    }
}
enum Sheet: String, Identifiable { case addWallet, send, contract, swap, bridge, privacyPool, receive, token, backup, manage; var id: String { rawValue } }
