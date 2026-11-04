import Foundation
import CPrivacyTransport

private final class MoneroCancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws { guard let value = veil_cancel_create() else { throw WalletError.invalid(L("message.could_not_allocate_a_local_rpc_request")) }; pointer = value }
    deinit { veil_cancel_destroy(pointer) }
    func cancel() { veil_cancel_set(pointer) }
}
struct MoneroLocalRPC: Sendable {
    let port: UInt16
    let password: String
    func call(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let allowed = ["get_version", "get_height", "get_balance", "get_address", "open_wallet", "close_wallet", "generate_from_keys", "auto_refresh", "refresh", "store", "transfer", "relay_tx", "get_transfer_by_txid"]
        guard allowed.contains(method) else { throw WalletError.invalid(L("message.this_local_monero_rpc_method_is_not_allowed")) }
        if method == "transfer" { guard params["do_not_relay"] == .bool(true), params["get_tx_metadata"] == .bool(true) else { throw WalletError.invalid(L("message.xmr_transaction_building_must_disable_broadcast_and_return_local_relay")) } }
        let id = UUID().uuidString
        let body = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)]))
        let token = try MoneroCancellation()
        let data: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let response = password.withCString { pass in body.withUnsafeBytes { bytes in
                            veil_monero_local(port, pass, bytes.bindMemory(to: UInt8.self).baseAddress, body.count, token.pointer)
                        } }
                        defer { veil_response_free(response) }
                        guard response.code == 0, response.status == 200, let bytes = response.bytes else { throw WalletError.invalid(L("message.local_monero_runtime_request_failed_no_external_wallet_service_fallback")) }
                        continuation.resume(returning: Data(bytes: bytes, count: response.length))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { token.cancel() }
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        guard result["id"] == .string(id), result["jsonrpc"] == .string("2.0") else { throw WalletError.invalid(L("message.local_monero_rpc_response_does_not_match")) }
        if let error = result["error"], error != .null {
            if case .number(let code) = error["code"] { throw WalletError.rpcRejected(code) }; throw WalletError.invalid(L("message.local_monero_rpc_rejected_the_request"))
        }
        guard let response = result["result"] else { throw WalletError.invalid(L("message.local_monero_rpc_result_missing")) }; return response
    }
}
