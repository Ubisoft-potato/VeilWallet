import Foundation
import Testing
import BigInt
@testable import WalletCore

private struct UTXOReferences: Decodable {
    struct Vector: Decodable { let profile: String; let material: String; let payload: NativeTransferPayload }
    let cases: [Vector]
    static func load() throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "transfer-reference", withExtension: "json")!)) }
}
private struct UTXOFixture {
    let vector: UTXOReferences.Vector
    let chain: Chain
    let archive: TransactionArchive
    let record: TransactionRecord
    let size: BigUInt
    init(profile: String, rbf: Bool = true) throws {
        vector = try #require(UTXOReferences.load().cases.first { $0.profile == profile })
        let account = try #require(AccountProfile.find(profile))
        chain = try #require(NetworkCatalog.nativeChains.first { $0.family == account.family })
        var payload = vector.payload; payload.replaceable = rbf
        let result = try MultichainCrypto.execute(.init(action: "transferSign", profile: account, key: vector.material, transfer: payload))
        let unsigned = try #require(result.unsigned), hash = try #require(result.hash), encoded = try #require(result.signed)
        let plan = NativeTransferPlan(chainID: chain.id, profileID: profile, family: chain.family, sender: payload.from, recipient: payload.to, amount: BigUInt(payload.amount)!, feeBudget: BigUInt(payload.fee)!, preparedAt: Date(), details: [], payload: payload, unsigned: unsigned)
        var item = Activity(walletID: UUID(), chainID: chain.id, hash: hash, to: plan.recipient, amount: "fixture", symbol: chain.symbol)
        var record = TransactionRecord.native(plan, groupID: item.id); record.broadcastAttempts = 1; record.observation = TransactionObservation(.pending); item.transaction = record
        var archive = try TransactionArchive(activityID: item.id, walletID: item.walletID, plan: plan, signed: .init(hash: hash, family: chain.family, chainID: chain.id, encoded: encoded)); archive.activity = item
        self.archive = archive; self.record = record
        size = try NativeTransferClient(transport: UTXONeverNetwork(), chain: chain, isolation: "fixture").inspectUTXOArchive(archive)
    }
    func client(descendant: Bool = false, conflict: Bool = false, ancestorConfirmed: Bool = true, confirmed: Bool = false, absentStatus: Int? = nil) -> NativeTransferClient {
        .init(transport: UTXOTestAPI(fixture: self, descendant: descendant, conflict: conflict, ancestorConfirmed: ancestorConfirmed, confirmed: confirmed, absentStatus: absentStatus), chain: chain, isolation: "fixture")
    }
}
private struct UTXONeverNetwork: PrivateRequesting { func execute(_ request: PrivateRequest) async throws -> Data { throw WalletError.invalid("Offline inspection attempted networking") } }
private struct UTXOTestAPI: PrivateRequesting {
    let fixture: UTXOFixture
    var descendant = false, conflict = false, ancestorConfirmed = true, confirmed = false
    var absentStatus: Int?
    private let child = String(repeating: "ab", count: 32)
    func execute(_ request: PrivateRequest) async throws -> Data {
        let path = request.url.path, archive = fixture.archive
        let value: JSONValue
        if path.hasSuffix("block-height/0") { return Data((fixture.chain.family == .litecoin ? Litecoin.mainnetGenesis : "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f").utf8) }
        if path.hasSuffix("tx/" + archive.hash + "/status") {
            if let absentStatus { throw WalletError.http(absentStatus) }
            value = .object(["confirmed": .bool(false)])
        } else if path.hasSuffix("/status") { value = .object(["confirmed": .bool(ancestorConfirmed)]) }
        else if path.hasSuffix("tx/" + archive.hash) || path.hasSuffix("tx/" + child) {
            value = .object(["txid": .string(path.hasSuffix(child) ? child : archive.hash), "fee": .string(path.hasSuffix(child) ? "20000" : archive.native!.payload.fee), "weight": .string(String(fixture.size * 4)), "status": .object(["confirmed": .bool(confirmed)]), "vout": .array([.object([:]), .object([:])])])
        } else if path.hasSuffix("/outspends") {
            value = .array([.object(["spent": .bool(false)]), descendant && !path.contains(child) ? .object(["spent": .bool(true), "txid": .string(child), "status": .object(["confirmed": .bool(false)])]) : .object(["spent": .bool(false)])])
        } else if path.contains("/outspend/") {
            value = conflict ? .object(["spent": .bool(true), "txid": .string(child)]) : .object(["spent": .bool(false)])
        } else { throw WalletError.invalid("Unexpected UTXO management fixture endpoint") }
        return try JSONEncoder().encode(value)
    }
}
struct UTXOManagementTests {
    @Test(arguments: ["btc.legacy", "btc.nested", "btc.segwit", "btc.taproot", "ltc.legacy", "ltc.nested", "ltc.nested.compat", "ltc.segwit", "ltc.taproot"])
    func allTransparentTypesPreservePaymentAndValidateReplacementSignatures(profile: String) async throws {
        let fixture = try UTXOFixture(profile: profile), client = fixture.client()
        let speed = try await client.prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .speedUp, rateText: "20")
        #expect(speed.plan.recipient == fixture.archive.native!.recipient)
        #expect(speed.plan.amount == fixture.archive.native!.amount)
        #expect(speed.plan.payload.inputs == fixture.archive.native!.payload.inputs)
        #expect(speed.plan.feeBudget > fixture.archive.native!.feeBudget)
        try await client.revalidateUTXOManagement(speed)
        let profile = try #require(AccountProfile.find(profile))
        let signed = try MultichainCrypto.execute(.init(action: "transferSign", profile: profile, key: fixture.vector.material, transfer: speed.plan.payload))
        let archive = try TransactionArchive(activityID: UUID(), walletID: UUID(), plan: speed.plan, signed: .init(hash: signed.hash!, family: fixture.chain.family, chainID: fixture.chain.id, encoded: signed.signed!))
        #expect(try client.inspectUTXOArchive(archive) > 0)
        #expect(archive.hash != fixture.archive.hash)
        let cancel = try await client.prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .cancel, rateText: "20")
        let expected = fixture.chain.family == .litecoin ? try Litecoin.addressInfo(fixture.archive.sender).canonicalAddress : fixture.archive.sender
        #expect(cancel.plan.recipient == expected)
        #expect(cancel.plan.payload.change == "0")
        #expect(cancel.plan.amount + cancel.plan.feeBudget == fixture.archive.native!.payload.inputs.reduce(0) { $0 + BigUInt($1.value)! })
    }
    @Test func cpfpPreservesParentAndRequiresConfirmedAncestorsAndOwnUnspentChange() async throws {
        let fixture = try UTXOFixture(profile: "btc.segwit", rbf: false), client = fixture.client()
        do { _ = try await client.prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .speedUp, rateText: "30"); Issue.record("Non-RBF source replaced") } catch {}
        let child = try await client.prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .cpfp, rateText: "100")
        #expect(child.plan.payload.inputs.count == 1)
        #expect(child.plan.payload.inputs[0].txid == fixture.archive.hash)
        #expect(child.plan.payload.inputs[0].index == 1)
        #expect(child.plan.recipient == fixture.archive.sender)
        #expect(child.groupID != fixture.record.groupID)
        try await client.revalidateUTXOManagement(child)
        for bad in [fixture.client(conflict: true), fixture.client(ancestorConfirmed: false), fixture.client(confirmed: true)] {
            do { _ = try await bad.prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .cpfp, rateText: "100"); Issue.record("Unsafe CPFP package accepted") } catch {}
        }
        let nested = TransactionRecord(groupID: UUID(), action: .cpfp, sender: fixture.archive.sender, profileID: "btc.segwit", sequence: nil, nativeCost: 1)
        do { _ = try await client.prepareUTXOManagement(archive: fixture.archive, record: nested, action: .cpfp, rateText: "100"); Issue.record("Nested CPFP underpriced ancestor package") } catch {}
    }
    @Test func replacementPaysForEvictedDescendantsAndRejectsChangedInputs() async throws {
        let fixture = try UTXOFixture(profile: "ltc.taproot")
        let normal = try await fixture.client().prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .speedUp, rateText: "1")
        let descendant = try await fixture.client(descendant: true).prepareUTXOManagement(archive: fixture.archive, record: fixture.record, action: .speedUp, rateText: "1")
        #expect(descendant.plan.feeBudget > normal.plan.feeBudget + 10_000)
        for bad in [fixture.client(descendant: true), fixture.client(conflict: true), fixture.client(confirmed: true)] {
            do { try await bad.revalidateUTXOManagement(normal); Issue.record("Changed replacement inputs / package accepted") } catch {}
        }
    }
    @Test func missingTransactionAndHTTPFailureNeverMeanCancelled() async throws {
        let fixture = try UTXOFixture(profile: "btc.segwit")
        #expect(try await fixture.client(absentStatus: 404).observe(activity: fixture.archive.activity!, archive: fixture.archive).phase == .notSeen)
        do { _ = try await fixture.client(absentStatus: 503).observe(activity: fixture.archive.activity!, archive: fixture.archive); Issue.record("RPC outage treated as absence") } catch WalletError.http(503) {}
    }
}
