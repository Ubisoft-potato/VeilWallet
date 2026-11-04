import Foundation
import Testing
@testable import WalletCore

private struct TronReceiptMock: PrivateRequesting {
    let scenario: String
    func execute(_ request: PrivateRequest) async throws -> Data {
        let hash = String(repeating: "1", count: 64)
        let value: JSONValue
        if request.url.path == "/wallet/getblockbynum" {
            value = .object(["blockID": .string("00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc")])
        } else if request.url.path == "/wallet/gettransactionbyid" || request.url.path == "/walletsolidity/gettransactionbyid" {
            value = .object(["txID": .string(hash), "ret": .array([.object(["contractRet": .string("SUCCESS")])]), "raw_data": .object(["contract": .array([.object(["type": .string(scenario == "native" ? "TransferContract" : "TriggerSmartContract"), "parameter": .object(["value": .object(["data": .string("095ea7b3")])])])])])])
        } else if request.url.path == "/walletsolidity/gettransactioninfobyid" {
            if scenario == "pending" { value = .object([:]) }
            else {
                var result: [String: JSONValue] = ["id": .string(hash), "blockNumber": .number(100)]
                if scenario != "missing" {
                    result["receipt"] = .object(["result": .string(scenario == "revert" ? "REVERT" : "SUCCESS")])
                    result["contractResult"] = .array([.string(scenario == "falseApprove" ? String(repeating: "0", count: 64) : "")])
                }
                value = .object(result)
            }
        } else { throw WalletError.invalid("Unexpected receipt path") }
        return try JSONEncoder().encode(value)
    }
}

struct TronReceiptTests {
    @Test(arguments: ["native", "success", "revert", "missing", "pending", "falseApprove"])
    func contractSuccessRequiresSolidifiedExecutionReceipt(scenario: String) async throws {
        let client = NativeTransferClient(transport: TronReceiptMock(scenario: scenario), chain: NetworkCatalog.nativeChains.first { $0.family == .tron }!, isolation: "test")
        do {
            let status = try await client.receipt(hash: String(repeating: "1", count: 64))
            let item = Activity(walletID: UUID(), chainID: client.chain.id, hash: String(repeating: "1", count: 64), to: "public fixture", amount: "1", symbol: "TRX")
            let managed = try await client.observe(activity: item)
            switch scenario {
            case "native", "success": #expect(status == "已确认"); #expect(managed.phase == .confirmed)
            case "revert", "falseApprove": #expect(status == "执行失败"); #expect(managed.phase == .failed)
            case "pending": #expect(status == "待确认"); #expect(managed.phase == .pending)
            default: Issue.record("Missing execution result accepted")
            }
        } catch { if scenario != "missing" { throw error } }
    }
}
