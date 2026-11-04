import Foundation
import BigInt

public struct BridgeStatus: Sendable {
    public let record: BridgeTransferRecord
    public let label: String
}
extension BridgeClient {
    /// Source confirmation is never reported as destination delivery. A supplied
    /// destination hash must match the source GUID and exact recipient on-chain.
    public func status(record: BridgeTransferRecord, sourceHash: String, destinationHash: String? = nil) async throws -> BridgeStatus {
        guard let source = BridgeCatalog.find(record.sourceID), let destination = BridgeCatalog.find(record.destinationID), BridgeCatalog.destinations(for: source).contains(destination),
              let minimum = BigUInt(record.minimumDestination), minimum > 0 else { throw WalletError.invalid(L("message.invalid_bridge_activity_metadata")) }
        let from = try endpoint(source.networkID), to = try endpoint(destination.networkID)
        var record = record
        record.destinationVerified = false
        guard let sourceReceipt = try await receipt(sourceHash, endpoint: from) else { return .init(record: record, label: L("message.source_confirmation_pending")) }
        let sender = source.bridgeProtocol == .allbridgeOFT ? source.contract : record.sender
        let topic = Self.event("OFTSent(bytes32,uint32,address,uint256,uint256)")
        let sent = try Self.eventLog(sourceReceipt, topic: topic, contract: record.sourceOFT, network: source.networkID)
        guard sent.topics.count == 3, sent.topics[2].lowercased() == (try BridgeEndpoint.word(sender, networkID: source.networkID)).lowercased(), sent.data.count == 96,
              BigUInt(sent.data.prefix(32)) == BigUInt(destination.endpointID), BigUInt(sent.data[32..<64]) > 0, BigUInt(sent.data.suffix(32)) > 0 else { throw WalletError.invalid(L("message.the_source_oft_event_does_not_match_the_approved_route")) }
        let guid = sent.topics[1].lowercased()
        if let existing = record.guid, existing != guid { throw WalletError.invalid(L("message.the_bridge_guid_changed")) }; record.guid = guid
        guard let hash = destinationHash ?? record.destinationHash, !hash.isEmpty else { return .init(record: record, label: L("message.source_confirmed_destination_receipt_unverified")) }
        guard let destinationReceipt = try await receipt(hash, endpoint: to) else { return .init(record: record, label: L("message.destination_confirmation_pending")) }
        let received = try Self.eventLog(destinationReceipt, topic: Self.event("OFTReceived(bytes32,uint32,address,uint256)"), contract: record.destinationOFT, network: destination.networkID)
        guard received.topics.count == 3, received.topics[1].lowercased() == guid,
              received.topics[2].lowercased() == (try BridgeEndpoint.word(record.recipient, networkID: destination.networkID)).lowercased(), received.data.count == 64,
              BigUInt(received.data.prefix(32)) == BigUInt(source.endpointID), BigUInt(received.data.suffix(32)) >= minimum else { throw WalletError.invalid(L("message.destination_event_guid_recipient_or_amount_does_not_match")) }
        record.destinationHash = hash; record.destinationVerified = true
        return .init(record: record, label: L("message.bridge_receipt_verified"))
    }
    private func receipt(_ hash: String, endpoint: BridgeEndpoint) async throws -> JSONValue? {
        guard (try? Data(strictHex: hash).count) == 32 else { throw WalletError.invalid(L("message.invalid_bridge_transaction_hash_length")) }
        switch endpoint {
        case .evm(let rpc):
            try await rpc.verifyChain()
            let result = try await rpc.call("eth_getTransactionReceipt", params: [.string(hash)])
            if result == .null { return nil }
            guard result["transactionHash"]?.string?.lowercased() == hash.lowercased(), let status = result["status"]?.string,
                  try Ethereum.decodeQuantity(status) == 1 else { throw WalletError.invalid(L("message.bridge_execution_failed_or_its_receipt_is_invalid")) }
            let latest = try await rpc.call("eth_getBlockByNumber", params: [.string("latest"), .bool(false)])
            guard let height = result["blockNumber"]?.string, let head = latest["number"]?.string else { throw WalletError.invalid(L("message.bridge_receipt_is_missing_a_block_height")) }
            let block = try Ethereum.decodeQuantity(height), tip = try Ethereum.decodeQuantity(head)
            guard tip >= block else { throw WalletError.invalid(L("message.bridge_receipt_height_exceeds_the_node_s_latest_block")) }
            if tip - block + 1 < (rpc.chain.id == 56 ? 15 : 12) { return nil }
            let canonical = try await rpc.call("eth_getBlockByNumber", params: [.string(height), .bool(false)])
            guard let canonicalHash = canonical["hash"]?.string, (try? Data(strictHex: canonicalHash).count) == 32, canonical["number"] == .string(height), result["blockHash"]?.string?.lowercased() == canonicalHash.lowercased() else { throw WalletError.invalid(L("message.bridge_receipt_block_is_reorganized_or_invalid")) }
            return result
        case .tron(let tron):
            try await tron.verifyChain()
            let tx = try await tron.native.rest("walletsolidity/gettransactioninfobyid", body: .object(["value": .string(String(hash.replacingOccurrences(of: "0x", with: "")))]))
            if tx == .object([:]) { return nil }
            guard tx["id"]?.string?.lowercased() == hash.replacingOccurrences(of: "0x", with: "").lowercased(),
                  tx["receipt"]?["result"] == .string("SUCCESS"), (tx["result"] == nil || tx["result"] == .string("SUCESS")), try tron.native.integer(tx["blockNumber"]) > 0 else { throw WalletError.invalid(L("message.tron_solidified_bridge_execution_failed_or_its_receipt_is_invalid")) }
            return tx
        }
    }
    static func event(_ signature: String) -> String { "0x" + Data(signature.utf8).keccak256.hexString }
    static func eventLog(_ receipt: JSONValue, topic: String, contract: String, network: UInt64) throws -> (topics: [String], data: Data) {
        let key = network == TronAddress.chainID ? "log" : "logs"
        guard case .array(let rows) = receipt[key], rows.count <= 4096 else { throw WalletError.invalid(L("message.bridge_receipt_is_missing_events")) }
        let expected = try network == TronAddress.chainID ? TronAddress.evm(contract).lowercased() : contract.lowercased()
        let matches = rows.filter { row in
            guard let address = row["address"]?.string, case .array(let topics) = row["topics"], let first = topics.first?.string else { return false }
            return "0x" + address.lowercased().replacingOccurrences(of: "0x", with: "") == expected && "0x" + first.lowercased().replacingOccurrences(of: "0x", with: "") == topic
        }
        guard matches.count == 1, case .array(let rawTopics) = matches[0]["topics"], let raw = matches[0]["data"]?.string else { throw WalletError.invalid(L("message.bridge_event_is_missing_duplicated_or_from_another_contract")) }
        let topics = try rawTopics.map { value -> String in guard let text = value.string, (try? Data(strictHex: text).count) == 32 else { throw WalletError.invalid(L("message.invalid_bridge_event_topic")) }; return "0x" + text.replacingOccurrences(of: "0x", with: "") }
        return (topics, try Data(strictHex: raw))
    }
}
