import Foundation
import Testing
import BigInt
@testable import WalletCore

private let transactionKey = Data(repeating: 1, count: 32) // Public, never funded outside the isolated test chain.
private let transactionRecipient = "0x000000000000000000000000000000000000dEaD"
private func managedFixture(nonce: BigUInt = 0, mode: EVMTransactionMode = .eip1559, groupID: UUID? = nil, phase: TransactionPhase = .pending, action: TransactionAction = .original) throws -> (Activity, TransactionArchive) {
    let owner = try Ethereum.address(privateKey: transactionKey)
    let tx = try EVMTransaction(chainID: 1, nonce: nonce, maxPriorityFee: mode == .legacy ? 0 : 10, maxFee: 100, gasLimit: 50_000, to: transactionRecipient, value: 1_000_000, mode: mode)
    let preview = TransactionPreview(transaction: tx, sender: owner, recipient: transactionRecipient, amount: "0.000000000001", symbol: "ETH", preparedAt: Date(), token: nil, additionalFees: .zero, purpose: .transfer)
    let raw = try tx.signed(privateKey: transactionKey)
    var activity = Activity(walletID: UUID(), chainID: 1, hash: "0x" + raw.keccak256.hexString, to: transactionRecipient, amount: preview.amount, symbol: "ETH")
    activity.transaction = .evm(preview, groupID: groupID ?? activity.id, action: action); activity.transaction?.observation = TransactionObservation(phase)
    if phase != .queued { activity.transaction?.broadcastAttempts = 1 }
    var archive = try TransactionArchive(activityID: activity.id, walletID: activity.walletID, preview: preview, raw: raw); archive.activity = activity; return (activity, archive)
}
private struct ManagementRPC: PrivateRequesting {
    var latest: BigUInt = 0
    var pending: BigUInt = 1
    var mode: EVMTransactionMode = .eip1559
    var receipt: JSONValue = .null
    var tx: JSONValue = .null
    var wrongCanonical = false
    var delegated = false
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!)
        let method = body["method"]!.string!; guard case .array(let params) = body["params"] else { throw WalletError.invalid("Mock params") }
        let result: JSONValue
        switch method {
        case "eth_chainId": result = .string("0x1")
        case "eth_getTransactionCount": result = .string(Ethereum.quantity(params[1] == .string("latest") ? latest : pending))
        case "eth_getTransactionReceipt": result = receipt
        case "eth_getTransactionByHash": result = tx
        case "eth_getCode": result = .string(delegated ? "0xef01000000000000000000000000000000000000000000" : "0x")
        case "eth_getBalance": result = .string(Ethereum.quantity(BigUInt(10).power(25)))
        case "eth_gasPrice", "eth_maxPriorityFeePerGas": result = .string("0x1")
        case "eth_estimateGas": result = .string("0x5208")
        case "eth_getBlockByNumber":
            var fields: [String: JSONValue] = ["number": .string(params[0] == .string("latest") ? "0x10" : params[0].string!), "hash": .string("0x" + String(repeating: wrongCanonical ? "ab" : "aa", count: 32)), "timestamp": .string(Ethereum.quantity(BigUInt(Int(Date().timeIntervalSince1970))))]
            if mode == .eip1559 { fields["baseFeePerGas"] = .string("0x1") }; result = .object(fields)
        case "eth_sendRawTransaction": result = .string("0x" + (try Data(strictHex: params[0].string!)).keccak256.hexString)
        default: throw WalletError.invalid("Unexpected management mock RPC")
        }
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result]))
    }
}
struct TransactionManagementTests {
    let chain = Chain.defaults.first { $0.id == 1 }!
    @Test func nonceQueueReservesInvisibleTransactionsAndDetectsGaps() throws {
        let (zero, _) = try managedFixture(nonce: 0), (one, _) = try managedFixture(nonce: 1), (two, _) = try managedFixture(nonce: 2)
        let sender = zero.transaction!.sender
        let policy = EVMNoncePolicy(activities: [zero, one])
        #expect(try policy.next(chainID: 1, sender: sender, latest: 0, pending: 0) == 2)
        #expect(try policy.next(chainID: 1, sender: sender, latest: 1, pending: 1) == 2)
        let cost = BigUInt(zero.transaction!.nativeCost)!
        #expect(try policy.reserved(chainID: 1, sender: sender, latest: 0) == cost * 2)
        #expect(try policy.reserved(chainID: 1, sender: sender, latest: 1) == cost)
        let gap = EVMNoncePolicy(activities: [zero, two])
        #expect(try gap.gap(chainID: 1, sender: sender, latest: 0, pending: 0) == 1)
        do { _ = try gap.next(chainID: 1, sender: sender, latest: 0, pending: 0); Issue.record("Nonce gap silently skipped") } catch {}
        do { _ = try policy.next(chainID: 1, sender: sender, latest: 2, pending: 1); Issue.record("Inconsistent nonce accepted") } catch {}
        var discarded = zero; discarded.transaction?.observation = TransactionObservation(.discarded)
        #expect(try EVMNoncePolicy(activities: [discarded]).next(chainID: 1, sender: sender, latest: 0, pending: 0) == 0)
        // A reorg lowering latest must reserve an old signed nonce again, even
        // when its previous local label said confirmed.
        var previouslyConfirmed = zero; previouslyConfirmed.transaction?.observation = TransactionObservation(.confirmed)
        #expect(try EVMNoncePolicy(activities: [previouslyConfirmed]).next(chainID: 1, sender: sender, latest: 0, pending: 0) == 1)
    }
    @Test func mutuallyExclusiveReplacementsReserveMaximumNotSum() throws {
        let (original, _) = try managedFixture(), (duplicate, _) = try managedFixture(groupID: original.transaction!.groupID, action: .speedUp)
        let policy = EVMNoncePolicy(activities: [original, duplicate])
        #expect(try policy.reserved(chainID: 1, sender: original.transaction!.sender, latest: 0) == BigUInt(original.transaction!.nativeCost))
        #expect(try policy.reserved(chainID: 1, sender: original.transaction!.sender, latest: 0, excludingNonce: 0) == 0)
    }
    @Test func signedArchiveBindsEveryFieldAndSigner() throws {
        for mode in [EVMTransactionMode.legacy, .eip1559] {
            let (_, archive) = try managedFixture(mode: mode); try archive.validate()
            let tx = archive.evm!.transaction, raw = try Data(strictHex: archive.signedPayload)
            try tx.verifySigned(raw, sender: archive.sender)
            let changed = try EVMTransaction(chainID: tx.chainID, nonce: tx.nonce, maxPriorityFee: tx.maxPriorityFee, maxFee: tx.maxFee, gasLimit: tx.gasLimit, to: tx.to, value: tx.value + 1, mode: mode)
            do { try changed.verifySigned(raw, sender: archive.sender); Issue.record("Signed raw accepted a different amount") } catch {}
            do { try tx.verifySigned(raw, sender: transactionRecipient); Issue.record("Wrong signer accepted") } catch {}
            for damaged in [Data(raw.dropLast()), raw + Data([0]), Data([2, 0xff, 0xff, 0xff])] { do { try tx.verifySigned(damaged, sender: archive.sender); Issue.record("Malformed RLP accepted") } catch {} }
        }
    }
    @Test func speedUpAndCancelKeepNonceAndRequireRealFeeBump() async throws {
        for mode in [EVMTransactionMode.legacy, .eip1559] {
            let (activity, archive) = try managedFixture(mode: mode), rpc = RPCClient(transport: ManagementRPC(mode: mode), chain: chain, isolation: "test")
            let speed = try await rpc.prepareReplacement(archive: archive, record: activity.transaction!, action: .speedUp)
            #expect(speed.transaction.nonce == archive.evm!.transaction.nonce); #expect(speed.transaction.to == archive.evm!.transaction.to)
            #expect(speed.transaction.data == archive.evm!.transaction.data); #expect(speed.transaction.value == archive.evm!.transaction.value)
            #expect(speed.transaction.maxFee >= 125); #expect(mode == .legacy || speed.transaction.maxPriorityFee >= 13)
            try await rpc.revalidate(speed)
            let cancel = try await rpc.prepareReplacement(archive: archive, record: activity.transaction!, action: .cancel)
            #expect(cancel.transaction.to == archive.sender); #expect(cancel.transaction.value == 0); #expect(cancel.transaction.data.isEmpty)
            do { _ = try await rpc.prepareReplacement(archive: archive, record: activity.transaction!, action: .speedUp, maxFeeGwei: "0.000000100"); Issue.record("Underpriced replacement accepted") } catch {}
        }
        let (activity, archive) = try managedFixture()
        for transport in [ManagementRPC(latest: 1), ManagementRPC(receipt: .object(["status": .string("0x1")])), ManagementRPC(delegated: true)] {
            do { _ = try await RPCClient(transport: transport, chain: chain, isolation: "test").prepareReplacement(archive: archive, record: activity.transaction!, action: .cancel); Issue.record("Consumed nonce / existing receipt / delegated cancellation accepted") } catch {}
        }
    }
    @Test func replayPreservesHashAndOriginalFees() async throws {
        let (activity, archive) = try managedFixture()
        let rpc = RPCClient(transport: ManagementRPC(), chain: chain, isolation: "test", noncePolicy: .init(activities: [activity]))
        let replay = try rpc.replayPreview(archive: archive, record: activity.transaction!)
        #expect(replay.transaction == archive.evm!.transaction)
        try await rpc.revalidate(replay)
        #expect(try await rpc.broadcast(Data(strictHex: archive.signedPayload)) == archive.hash)
        let next = try await rpc.prepare(sender: archive.sender, recipient: transactionRecipient, amount: "0.001")
        #expect(next.transaction.nonce == 1)
    }
    @Test func missingNodeResponseDoesNotProveDroppedOrSuccessful() async throws {
        let (activity, _) = try managedFixture()
        let rpc = RPCClient(transport: ManagementRPC(pending: 0), chain: chain, isolation: "test")
        #expect(try await rpc.observe(activity: activity).phase == .notSeen)
        let used = RPCClient(transport: ManagementRPC(latest: 1), chain: chain, isolation: "test")
        #expect(try await used.observe(activity: activity).phase == .nonceConsumed)
    }
    @Test func canonicalReceiptConfirmationAndReorgValidation() async throws {
        let (activity, _) = try managedFixture()
        let receipt: JSONValue = .object(["transactionHash": .string(activity.hash), "from": .string(activity.transaction!.sender), "status": .string("0x1"), "blockNumber": .string("0x5"), "blockHash": .string("0x" + String(repeating: "aa", count: 32)), "gasUsed": .string("0x5208"), "effectiveGasPrice": .string("0x64")])
        let rpc = RPCClient(transport: ManagementRPC(receipt: receipt), chain: chain, isolation: "test")
        let result = try await rpc.observe(activity: activity)
        #expect(result.phase == .confirmed); #expect(result.confirmations == 12); #expect(result.executionFee == "2100000")
        let changed = RPCClient(transport: ManagementRPC(receipt: receipt, wrongCanonical: true), chain: chain, isolation: "test")
        #expect(try await changed.observe(activity: activity).phase == .reorged)
        let malformed = RPCClient(transport: ManagementRPC(receipt: .object(["status": .string("0x1")])), chain: chain, isolation: "test")
        do { _ = try await malformed.observe(activity: activity); Issue.record("Unmatched receipt accepted") } catch {}
    }
    @Test func encryptedJournalRecoversPartialCommitsAndDiscardRemovesSignature() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 7, count: 32), store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: key)
        let (activity, archive) = try managedFixture(phase: .queued)
        try await store.saveTransaction(archive)
        var recovered = try await store.recoverTransactions(into: [])
        #expect(recovered.count == 1); #expect(recovered[0].hash == activity.hash)
        let file = directory.appendingPathComponent("Transactions").appendingPathComponent(activity.id.uuidString + ".sealed")
        let ciphertext = try Data(contentsOf: file)
        #expect(!String(decoding: ciphertext, as: UTF8.self).contains(archive.signedPayload))
        var attempted = archive; attempted.activity?.transaction?.broadcastAttempts = 1; attempted.activity?.transaction?.observation = TransactionObservation(.broadcastUnknown)
        try await store.saveTransaction(attempted)
        recovered = try await store.recoverTransactions(into: recovered)
        #expect(recovered[0].transaction?.broadcastAttempts == 1); #expect(recovered[0].phase == .broadcastUnknown)
        do { try await store.removeUnbroadcastArchive(id: activity.id); Issue.record("Possibly sent signature discarded") } catch {}
        try await store.saveTransaction(archive)
        try await store.removeUnbroadcastArchive(id: activity.id)
        let discarded = try await store.transaction(id: activity.id)
        #expect(discarded.signedPayload.isEmpty); #expect(discarded.evm?.transaction == archive.evm?.transaction)
        #expect(discarded.activity?.phase == .discarded)
        var damaged = try Data(contentsOf: file); damaged[damaged.count / 2] ^= 1; try damaged.write(to: file)
        do { _ = try await store.transaction(id: activity.id); Issue.record("Damaged ciphertext accepted") } catch {}
    }
    @Test func singleWriterLeaseRejectsSecondInstanceAndReleasesOnExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: WalletSessionLease? = WalletSessionLease(); try first!.acquire(directory: directory)
        let second = WalletSessionLease()
        do { try second.acquire(directory: directory); Issue.record("Concurrent writer allowed") } catch {}
        first = nil; try second.acquire(directory: directory)
    }
}
