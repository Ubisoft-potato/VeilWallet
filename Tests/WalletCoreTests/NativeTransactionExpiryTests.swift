import Foundation
import Testing
import BigInt
@testable import WalletCore

private struct ExpiryReferences: Decodable {
    struct Vector: Decodable { let profile: String; let payload: NativeTransferPayload; let unsigned: String; let signed: String; let hash: String }
    let cases: [Vector]
}
private struct ExpiryAPI: PrivateRequesting {
    let family: NetworkFamily
    var available = false
    var outage = false
    func execute(_ request: PrivateRequest) async throws -> Data {
        if outage { throw WalletError.http(503) }
        let path = request.url.path, value: JSONValue
        switch family {
        case .solana:
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body!), result: JSONValue
            switch body["method"]?.string {
            case "getGenesisHash": result = .string("5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d")
            case "getSignatureStatuses": result = .object(["value": .array([.null])])
            case "isBlockhashValid": result = .object(["value": .bool(available)])
            default: throw WalletError.invalid("Unexpected expiry fixture RPC")
            }
            value = .object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": result])
        case .aptos:
            if path.contains("/by_hash/") { throw WalletError.http(404) }
            value = .object(["chain_id": .number(1), "ledger_timestamp": .string(available ? "0" : "9999999999000000")])
        case .cosmos:
            if path.hasSuffix("node_info") { value = .object(["default_node_info": .object(["network": .string("cosmoshub-4")])]) }
            else if path.hasSuffix("latest") { value = .object(["block": .object(["header": .object(["chain_id": .string("cosmoshub-4"), "height": .string(available ? "1" : "9999999999"), "time": .string(ISO8601DateFormatter().string(from: Date()))])])]) }
            else { throw WalletError.http(404) }
        case .tron:
            if path.hasSuffix("getblockbynum") { value = .object(["blockID": .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc")]) }
            else if path.hasSuffix("getnowblock") { value = .object(["block_header": .object(["raw_data": .object(["timestamp": .string(available ? "0" : "9999999999000")])])]) }
            else { value = .object([:]) }
        default: throw WalletError.invalid("Unsupported expiry fixture family")
        }
        return try JSONEncoder().encode(value)
    }
}
struct NativeTransactionExpiryTests {
    @Test(arguments: ["solana", "aptos", "tron", "cosmos"])
    func queuedSignaturesStillCheckChainExpiryBeforeFirstReplay(profileID: String) async throws {
        let references = try JSONDecoder().decode(ExpiryReferences.self, from: Data(contentsOf: Bundle.module.url(forResource: "transfer-reference", withExtension: "json")!))
        let vector = try #require(references.cases.first { $0.profile == profileID }), profile = try #require(AccountProfile.find(profileID))
        let chain = try #require(NetworkCatalog.nativeChains.first { $0.profileKeys.contains(profileID) })
        let plan = NativeTransferPlan(chainID: chain.id, profileID: profileID, family: profile.family, sender: vector.payload.from, recipient: vector.payload.to, amount: BigUInt(vector.payload.amount)!, feeBudget: BigUInt(vector.payload.fee)!, preparedAt: Date(), details: [], payload: vector.payload, unsigned: vector.unsigned)
        var item = Activity(walletID: UUID(), chainID: chain.id, hash: vector.hash, to: plan.recipient, amount: "1", symbol: chain.symbol)
        item.transaction = .native(plan, groupID: item.id)
        var archive = try TransactionArchive(activityID: item.id, walletID: item.walletID, plan: plan, signed: .init(hash: vector.hash, family: chain.family, chainID: chain.id, encoded: vector.signed)); archive.activity = item
        let expired = NativeTransferClient(transport: ExpiryAPI(family: chain.family), chain: chain, isolation: "fixture")
        #expect(try await expired.observe(activity: item, archive: archive).phase == .queued)
        do { try await expired.validateReplay(archive: archive); Issue.record("Expired queued signature allowed replay") } catch {}
        item.transaction?.broadcastAttempts = 1; item.transaction?.observation = TransactionObservation(.broadcastUnknown)
        #expect(try await expired.observe(activity: item, archive: archive).phase == .expired)
        let valid = NativeTransferClient(transport: ExpiryAPI(family: chain.family, available: true), chain: chain, isolation: "fixture")
        #expect(try await valid.observe(activity: item, archive: archive).phase == .notSeen)
        let outage = NativeTransferClient(transport: ExpiryAPI(family: chain.family, outage: true), chain: chain, isolation: "fixture")
        do { _ = try await outage.observe(activity: item, archive: archive); Issue.record("Outage was treated as expired") } catch WalletError.http(503) {}
    }
}
