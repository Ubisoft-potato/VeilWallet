import Foundation
import Testing
@testable import WalletCore

struct DexApprovalTests {
    private let sender = "0x000000000000000000000000000000000000dEaD"
    private let walletID = UUID()
    private func activity(_ phase: TransactionPhase, action: TransactionAction = .original, group: UUID = UUID(), hash: String = "0x" + String(repeating: "1", count: 64), chainID: UInt64 = 56) -> Activity {
        var item = Activity(walletID: walletID, chainID: chainID, hash: hash, to: sender, amount: "0", symbol: "BNB")
        item.transaction = .init(groupID: group, action: action, sender: sender, profileID: "evm", sequence: "1", nativeCost: 0, phase: phase)
        item.transaction?.observation.executionSucceeded = true
        item.transaction?.observation.confirmations = chainID == 56 ? 15 : 12; item.transaction?.observation.requiredConfirmations = chainID == 56 ? 15 : 12
        item.transaction?.observation.blockNumber = "100"; item.transaction?.observation.blockHash = "0x" + String(repeating: "a", count: 64)
        return item
    }
    private func resolve(_ original: Activity, _ all: [Activity]? = nil) -> DexApprovalProgress {
        .resolve(hash: original.hash, activities: all ?? [original], walletID: walletID, chainID: 56, sender: sender)
    }
    @Test(arguments: TransactionPhase.allCases)
    func onlyCanonicalConfirmedApprovalCanContinue(phase: TransactionPhase) {
        let item = activity(phase), result = resolve(item)
        if phase == .confirmed { #expect(result == .ready) }
        else if [.failed, .cancelled, .expired, .conflicted, .discarded].contains(phase) {
            guard case .stopped = result else { Issue.record("Failed approval can continue"); return }
        } else {
            guard case .waiting = result else { Issue.record("Unresolved approval can continue"); return }
        }
    }
    @Test(arguments: Array(Set(DexCatalog.all.map(\.chainID))).sorted())
    func approvalContinuationUsesEachConfiguredEVMNetwork(chainID: UInt64) {
        var item = activity(.confirmed, chainID: chainID)
        #expect(DexApprovalProgress.resolve(hash: item.hash, activities: [item], walletID: walletID, chainID: chainID, sender: sender) == .ready)
        item.transaction?.observation.confirmations = 0
        #expect(DexApprovalProgress.resolve(hash: item.hash, activities: [item], walletID: walletID, chainID: chainID, sender: sender) != .ready)
    }
    @Test func confirmationThresholdExecutionAndAccountMustAllMatch() {
        let good = activity(.confirmed)
        var malformed = good; malformed.transaction?.observation.confirmations = 14
        #expect(resolve(malformed) != .ready)
        malformed = good; malformed.transaction?.observation.executionSucceeded = nil
        #expect(resolve(malformed) != .ready)
        malformed = good; malformed.transaction?.observation.executionSucceeded = false
        #expect(resolve(malformed) != .ready)
        malformed = good; malformed.transaction?.observation.requiredConfirmations = 12
        #expect(resolve(malformed) != .ready)
        malformed = good; malformed.transaction?.observation.blockHash = nil
        #expect(resolve(malformed) != .ready)
        #expect(DexApprovalProgress.resolve(hash: good.hash, activities: [good], walletID: UUID(), chainID: 56, sender: sender) != .ready)
        #expect(DexApprovalProgress.resolve(hash: good.hash, activities: [good], walletID: walletID, chainID: 1, sender: sender) != .ready)
        #expect(DexApprovalProgress.resolve(hash: good.hash, activities: [good], walletID: walletID, chainID: 56, sender: "0x1111111111111111111111111111111111111111") != .ready)
    }
    @Test func verifiedSpeedUpCanContinueButCancellationOrUnknownReplacementCannot() {
        let group = UUID(), winnerHash = "0x" + String(repeating: "2", count: 64)
        var original = activity(.replaced, group: group)
        original.transaction?.observation.winningHash = winnerHash
        let speedUp = activity(.confirmed, action: .speedUp, group: group, hash: winnerHash)
        #expect(resolve(original, [original, speedUp]) == .ready)
        #expect(resolve(original) != .ready)
        let cancel = activity(.cancelled, action: .cancel, group: group, hash: winnerHash)
        guard case .stopped = resolve(original, [original, cancel]) else { Issue.record("Cancelled approval can continue"); return }
        let unrelated = activity(.confirmed, action: .speedUp, hash: winnerHash)
        #expect(resolve(original, [original, unrelated]) != .ready)
        let failed = activity(.failed, action: .speedUp, group: group, hash: winnerHash)
        guard case .stopped = resolve(original, [original, failed]) else { Issue.record("Failed replacement can continue"); return }
    }
}
