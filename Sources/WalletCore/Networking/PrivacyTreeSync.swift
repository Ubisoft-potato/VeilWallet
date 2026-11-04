import Foundation
import BigInt

public struct PrivacyTreeSnapshot: Codable, Sendable {
    public let poolID: String
    public var scannedBlock: UInt64
    public var blockHash: String
    public var leaves: [String]
    public init(pool: PrivacyPool) { poolID = pool.id; scannedBlock = pool.deploymentBlock - 1; blockHash = ""; leaves = [] }
}
public struct PrivacyTreeProgress: Sendable {
    public let snapshot: PrivacyTreeSnapshot
    public let targetBlock: UInt64
    public var complete: Bool { snapshot.scannedBlock == targetBlock }
}
extension PrivacyPoolClient {
    static var depositTopic: String { "0x" + Data("Deposit(bytes32,uint32,uint256)".utf8).keccak256.hexString }
    /// Full-pool topic only; never filter by an owned commitment or leaf index.
    public func synchronize(pool: PrivacyPool, snapshot: PrivacyTreeSnapshot?, progress: @Sendable (PrivacyTreeProgress) async throws -> Void) async throws -> PrivacyTreeProgress {
        _ = try await verify(pool)
        var cache = snapshot ?? PrivacyTreeSnapshot(pool: pool)
        guard cache.poolID == pool.id, cache.scannedBlock >= pool.deploymentBlock - 1, cache.leaves.count <= 1 << 20 else { throw WalletError.invalid(L("message.deposit_tree_cache_belongs_to_a_different_pool")) }
        if !cache.blockHash.isEmpty {
            let anchor = try await block(cache.scannedBlock)
            // Fail closed. The UI offers explicit cache reset after a reorg.
            guard anchor.hash == cache.blockHash else { throw WalletError.invalid(L("message.the_deposit_tree_anchor_was_reorganized_clear_this_pool_s")) }
        }
        let latest = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
        guard let number = latest["number"]?.string, let target = UInt64(exactly: try Ethereum.decodeQuantity(number)), target >= cache.scannedBlock else { throw WalletError.invalid(L("message.the_node_s_latest_block_is_invalid_or_behind_the")) }
        var range: UInt64 = 100_000, chunks = 0
        while cache.scannedBlock < target, chunks < 64 {
            try Task.checkCancellation()
            let from = cache.scannedBlock + 1, to = min(target, from + range - 1)
            let response: JSONValue
            do {
                response = try await rpc.call("eth_getLogs", params: [.object(["address": .string(pool.contract), "fromBlock": .string(Ethereum.quantity(BigUInt(from))), "toBlock": .string(Ethereum.quantity(BigUInt(to))), "topics": .array([.string(Self.depositTopic)])])])
            } catch WalletError.rpcRejected(let code) where [-32005, -32602, -32000].contains(code) && range > 100 {
                range = max(100, range / 2); continue
            } catch WalletError.transport(23) where range > 100 {
                // The bounded curl sink rejected >8 MiB, never an empty result.
                range = max(100, range / 2); continue
            }
            let leaves = try Self.depositLeaves(response, pool: pool, from: from, to: to, startIndex: cache.leaves.count)
            let anchor = try await block(to)
            // Logs and anchor must come from the same canonical block view.
            if case .array(let logs) = response {
                for log in logs where log["blockNumber"]?.string == Ethereum.quantity(BigUInt(to)) {
                    guard log["blockHash"]?.string?.lowercased() == anchor.hash else { throw WalletError.invalid(L("message.a_chain_reorganization_occurred_during_sync_retry_this_batch")) }
                }
            }
            cache.leaves += leaves; cache.scannedBlock = to; cache.blockHash = anchor.hash; chunks += 1
            try await progress(.init(snapshot: cache, targetBlock: target))
        }
        return .init(snapshot: cache, targetBlock: target)
    }
    private func block(_ number: UInt64) async throws -> (hash: String, number: UInt64) {
        let value = try await rpc.call("eth_getBlockByNumber", params: [.string(Ethereum.quantity(BigUInt(number))), .bool(false)])
        guard let hash = value["hash"]?.string?.lowercased(), (try? Data(strictHex: hash).count) == 32,
              let quantity = value["number"]?.string, try Ethereum.decodeQuantity(quantity) == BigUInt(number) else { throw WalletError.invalid(L("message.invalid_deposit_tree_block_anchor")) }
        return (hash, number)
    }
    static func depositLeaves(_ response: JSONValue, pool: PrivacyPool, from: UInt64, to: UInt64, startIndex: Int) throws -> [String] {
        guard case .array(let logs) = response, logs.count <= 65_536, startIndex + logs.count <= 1 << 20 else { throw WalletError.invalid(L("message.invalid_deposit_event_count")) }
        var indexed: [(Int, String)] = []
        for log in logs {
            guard log["address"]?.string?.lowercased() == pool.contract.lowercased(), log["removed"] == .bool(false),
                  case .array(let topics) = log["topics"], topics.count == 2, topics[0].string?.lowercased() == depositTopic,
                  let commitment = topics[1].string, (try? Data(strictHex: commitment).count) == 32,
                  let text = log["data"]?.string, let data = try? Data(strictHex: text), data.count == 64,
                  let index = Int(exactly: BigUInt(data.prefix(32))), index < 1 << 20,
                  let n = log["blockNumber"]?.string, let number = UInt64(exactly: try Ethereum.decodeQuantity(n)), (from...to).contains(number),
                  let hash = log["blockHash"]?.string, (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.incorrect_pool_event_format_source_or_block_range")) }
            indexed.append((index, commitment.lowercased()))
        }
        indexed.sort { $0.0 < $1.0 }
        guard indexed.enumerated().allSatisfy({ $0.element.0 == startIndex + $0.offset }) else { throw WalletError.invalid(L("message.deposit_leaf_indices_are_missing_or_duplicated_the_node_may")) }
        return indexed.map(\.1)
    }
}
