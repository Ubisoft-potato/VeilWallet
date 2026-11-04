import Foundation
import BigInt

public struct EVMFeeQuote: Sendable {
    public let mode: EVMTransactionMode
    public let maxPriorityFee: BigUInt
    public let maxFee: BigUInt
}
public struct EVMAdditionalFees: Codable, Equatable, Sendable {
    public let l1DataFee: BigUInt
    public let operatorFee: BigUInt
    public var estimated: BigUInt { l1DataFee + operatorFee }
    // A budget, not a protocol-enforced cap. Reject a stale quote before signing.
    public var budget: BigUInt { (estimated * 120 + 99) / 100 }
    public static let zero = EVMAdditionalFees(l1DataFee: 0, operatorFee: 0)
}
private enum FeeContractError: Error { case unavailable }

enum EVMFeeEstimator {
    static let opOracle = "0x420000000000000000000000000000000000000F"
    static let l1Block = "0x4200000000000000000000000000000000000015"
    static let scrollOracle = "0x5300000000000000000000000000000000000002"
    static func additional(client: RPCClient, transaction: EVMTransaction) async throws -> EVMAdditionalFees {
        switch client.chain.evmFeeModel {
        case .opStack:
            let l1 = try await opL1Fee(client, transaction: transaction)
            let fee = try await operatorFee(client, gas: transaction.gasLimit)
            return EVMAdditionalFees(l1DataFee: l1, operatorFee: fee)
        case .mantle:
            let active: BigUInt
            do { active = try await uint(client, address: opOracle, signature: "isArsia()") }
            catch {
                guard interfaceUnavailable(error), try await string(client, address: opOracle, signature: "version()") == "1.1.0" else { throw error }
                // The known pre-Arsia oracle has no separate L1/operator fee.
                return .zero
            }
            guard active <= 1 else { throw WalletError.invalid(L("message.the_mantle_fee_contract_returned_an_invalid_boolean")) }
            if active == 0 { return .zero } // Pre-Arsia eth_estimateGas already includes the fee components.
            let l1 = try await opL1Fee(client, transaction: transaction)
            let fee = try await uint(client, address: opOracle, signature: "getOperatorFee(uint256)", argument: transaction.gasLimit)
            return EVMAdditionalFees(l1DataFee: l1, operatorFee: fee)
        case .scroll:
            let l1 = try await bytesCall(client, address: scrollOracle, signature: "getL1Fee(bytes)", argument: transaction.feeEstimationSerialized)
            return EVMAdditionalFees(l1DataFee: l1, operatorFee: 0)
        default: return .zero
        }
    }
    private static func opL1Fee(_ client: RPCClient, transaction: EVMTransaction) async throws -> BigUInt {
        do { return try await uint(client, address: opOracle, signature: "getL1FeeUpperBound(uint256)", argument: BigUInt(transaction.unsignedSerialized.count)) }
        catch {
            guard interfaceUnavailable(error) else { throw error }
            return try await bytesCall(client, address: opOracle, signature: "getL1Fee(bytes)", argument: transaction.unsignedSerialized)
        }
    }
    private static func operatorFee(_ client: RPCClient, gas: BigUInt) async throws -> BigUInt {
        do { return try await uint(client, address: opOracle, signature: "getOperatorFee(uint256)", argument: gas) }
        catch {
            guard interfaceUnavailable(error) else { throw error }
            // Earlier upstream OP oracle versions expose no getOperatorFee. Only use
            // a documented older interface after reading the deployed version.
            let version = try await string(client, address: opOracle, signature: "version()")
            guard version.range(of: #"^1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$"#, options: .regularExpression) != nil else { throw WalletError.invalid(L("message.unknown_op_fee_contract_version_estimation_is_blocked")) }
            let parts = version.split(separator: "-")[0].split(separator: ".")
            guard parts.count == 3, parts[0] == "1", let minor = Int(parts[1]), Int(parts[2]) != nil else { throw WalletError.invalid(L("message.unknown_op_fee_contract_version_estimation_is_blocked")) }
            if minor <= 3 { return 0 } // Pre-Isthmus: no operator fee.
            guard minor <= 6 else { throw WalletError.invalid(L("message.this_op_fee_contract_lacks_a_supported_operator_fee_interface")) }
            let active = try await uint(client, address: opOracle, signature: "isIsthmus()")
            guard active <= 1 else { throw WalletError.invalid(L("message.the_op_fee_contract_returned_an_invalid_boolean")) }
            if active == 0 { return 0 }
            let scalar = try await uint(client, address: l1Block, signature: "operatorFeeScalar()")
            let constant = try await uint(client, address: l1Block, signature: "operatorFeeConstant()")
            guard scalar.bitWidth <= 32, constant.bitWidth <= 64 else { throw WalletError.invalid(L("message.op_operator_fee_parameters_are_out_of_range")) }
            if minor == 6 {
                let jovian = try await uint(client, address: opOracle, signature: "isJovian()")
                guard jovian <= 1 else { throw WalletError.invalid(L("message.the_op_fee_contract_returned_an_invalid_boolean")) }
                if jovian == 1 { return gas * scalar * 100 + constant }
            }
            return gas * scalar / 1_000_000 + constant
        }
    }
    static func uint(_ client: RPCClient, address: String, signature: String, argument: BigUInt? = nil) async throws -> BigUInt {
        var payload = Data(signature.utf8).keccak256.prefix(4)
        if let argument { payload += word(argument) }
        return try decodeWord(await call(client, address: address, payload: Data(payload)))
    }
    private static func bytesCall(_ client: RPCClient, address: String, signature: String, argument: Data) async throws -> BigUInt {
        let padding = (32 - argument.count % 32) % 32
        let payload = Data(Data(signature.utf8).keccak256.prefix(4)) + word(32) + word(BigUInt(argument.count)) + argument + Data(repeating: 0, count: padding)
        return try decodeWord(await call(client, address: address, payload: payload))
    }
    private static func call(_ client: RPCClient, address: String, payload: Data) async throws -> Data {
        let response = try await client.call("eth_call", params: [.object(["to": .string(address), "data": .string("0x" + payload.hexString)]), .string("latest")])
        guard let hex = response.string else { throw WalletError.invalid(L("message.the_fee_contract_returned_invalid_data")) }
        let data = try Data(strictHex: hex)
        guard !data.isEmpty else { throw FeeContractError.unavailable }
        return data
    }
    private static func decodeWord(_ data: Data) throws -> BigUInt {
        guard data.count == 32 else { throw WalletError.invalid(L("message.the_fee_contract_result_is_not_uint256")) }; return BigUInt(data)
    }
    private static func string(_ client: RPCClient, address: String, signature: String) async throws -> String {
        let data = try await call(client, address: address, payload: Data(Data(signature.utf8).keccak256.prefix(4)))
        guard data.count >= 96, BigUInt(data.prefix(32)) == 32 else { throw WalletError.invalid(L("message.invalid_fee_contract_version")) }
        let length = BigUInt(data[32..<64])
        guard length > 0, length <= 48 else { throw WalletError.invalid(L("message.invalid_fee_contract_version")) }
        let count = Int(length)
        guard data.count == 64 + ((count + 31) / 32) * 32, data.dropFirst(64 + count).allSatisfy({ $0 == 0 }), let result = String(data: data[64..<(64 + count)], encoding: .utf8) else { throw WalletError.invalid(L("message.invalid_fee_contract_version")) }
        return result
    }
    static func word(_ value: BigUInt) -> Data { let raw = value.serialize(); return Data(repeating: 0, count: max(0, 32 - raw.count)) + raw }
    private static func interfaceUnavailable(_ error: Error) -> Bool {
        if case FeeContractError.unavailable = error { return true }
        if case WalletError.rpcRejected(let code) = error { return [-32601, -32000, -32015, 3].contains(code) }
        return false
    }
}
