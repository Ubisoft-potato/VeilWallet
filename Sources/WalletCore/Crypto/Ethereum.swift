import Foundation
import BigInt

public enum Ethereum {
    public static func address(privateKey: Data) throws -> String {
        let pub = try Secp256k1.publicKey(privateKey: privateKey, compressed: false)
        return checksumAddress(Data(pub.dropFirst()).keccak256.suffix(20).hexString)
    }
    public static func checksumAddress(_ hex: String) -> String {
        let lower = hex.lowercased().replacingOccurrences(of: "0x", with: "")
        let hash = Data(lower.utf8).keccak256.hexString
        return "0x" + zip(lower, hash).map { char, nibble in
            (Int(String(nibble), radix: 16) ?? 0) >= 8 ? String(char).uppercased() : String(char)
        }.joined()
    }
    public static func validateAddress(_ address: String) -> Bool {
        guard address.hasPrefix("0x"), address.count == 42, (try? Data(strictHex: address)) != nil else { return false }
        let body = String(address.dropFirst(2))
        return body == body.lowercased() || body == body.uppercased() || checksumAddress(body) == address
    }
    public static func parseUnits(_ text: String, decimals: Int = 18) throws -> BigUInt {
        guard (0...36).contains(decimals), !text.isEmpty, text.count <= 120 else { throw WalletError.invalid(L("message.invalid_amount")) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty, parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw WalletError.invalid(L("message.amounts_accept_decimal_digits_only_without_exponents_or_negative_values"))
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals, let value = BigUInt(String(parts[0]) + fraction + String(repeating: "0", count: decimals - fraction.count)), value.bitWidth <= 256 else {
            throw WalletError.invalid(L("message.amount_precision_or_range_exceeds_the_limit"))
        }
        return value
    }
    public static func formatUnits(_ value: BigUInt, decimals: Int = 18, precision: Int = 8) -> String {
        guard decimals > 0 else { return String(value) }
        let base = BigUInt(10).power(decimals)
        let integer = String(value / base)
        let raw = String(value % base)
        let padded = String(repeating: "0", count: max(0, decimals - raw.count)) + raw
        let fraction = String(padded.prefix(precision)).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return fraction.isEmpty ? integer : integer + "." + fraction
    }
    public static func quantity(_ value: BigUInt) -> String { "0x" + String(value, radix: 16) }
    public static func decodeQuantity(_ value: String) throws -> BigUInt {
        guard value.hasPrefix("0x"), value.count > 2, value.count <= 66,
              let result = BigUInt(value.dropFirst(2), radix: 16) else { throw WalletError.invalid(L("message.the_node_returned_an_invalid_number")) }
        return result
    }
    public static func transferData(to: String, amount: BigUInt) throws -> Data {
        guard validateAddress(to), amount.bitWidth <= 256 else { throw WalletError.invalid(L("message.invalid_token_transfer")) }
        return try Data(strictHex: "a9059cbb" + String(repeating: "0", count: 24) + String(to.dropFirst(2)) + String(repeating: "0", count: 64 - String(amount, radix: 16).count) + String(amount, radix: 16))
    }
    public static func personalSign(message: Data, privateKey: Data) throws -> Data {
        let prefix = Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8)
        let sig = try Secp256k1.sign(hash: (prefix + message).keccak256, privateKey: privateKey)
        return sig.r + sig.s + Data([sig.recovery + 27])
    }
}

public indirect enum RLP {
    case bytes(Data)
    case list([RLP])
    public static func number(_ value: BigUInt) -> RLP { .bytes(value == 0 ? Data() : value.serialize()) }
    public var encoded: Data {
        switch self {
        case .bytes(let bytes):
            if bytes.count == 1, bytes.first! < 0x80 { return bytes }
            return prefix(length: bytes.count, offset: 0x80) + bytes
        case .list(let items):
            let body = items.reduce(Data()) { $0 + $1.encoded }
            return prefix(length: body.count, offset: 0xc0) + body
        }
    }
    private func prefix(length: Int, offset: UInt8) -> Data {
        if length < 56 { return Data([offset + UInt8(length)]) }
        let bytes = BigUInt(length).serialize()
        return Data([offset + 55 + UInt8(bytes.count)]) + bytes
    }
}

public enum EVMTransactionMode: String, Codable, Sendable { case eip1559, legacy }

public struct EVMTransaction: Codable, Equatable, Sendable {
    public let mode: EVMTransactionMode
    public let chainID: UInt64
    public let nonce: BigUInt
    public let maxPriorityFee: BigUInt
    public let maxFee: BigUInt
    public let gasLimit: BigUInt
    public let to: String
    public let value: BigUInt
    public let data: Data
    public init(chainID: UInt64, nonce: BigUInt, maxPriorityFee: BigUInt, maxFee: BigUInt, gasLimit: BigUInt, to: String, value: BigUInt, data: Data = Data(), mode: EVMTransactionMode = .eip1559) throws {
        guard chainID > 0, Ethereum.validateAddress(to), maxFee >= maxPriorityFee,
              gasLimit >= 21000, gasLimit <= 30_000_000,
              [nonce, maxPriorityFee, maxFee, value].allSatisfy({ $0.bitWidth <= 256 }), data.count <= 128_000 else { throw WalletError.invalid(L("message.invalid_evm_transaction_parameters")) }
        guard mode != .legacy || maxPriorityFee == 0 else { throw WalletError.invalid(L("message.legacy_transactions_cannot_set_a_priority_fee")) }
        self.mode = mode; self.chainID = chainID; self.nonce = nonce; self.maxPriorityFee = maxPriorityFee; self.maxFee = maxFee
        self.gasLimit = gasLimit; self.to = to; self.value = value; self.data = data
    }
    private var fields: [RLP] {
        [.number(BigUInt(chainID)), .number(nonce), .number(maxPriorityFee), .number(maxFee), .number(gasLimit), .bytes((try? Data(strictHex: to)) ?? Data()), .number(value), .bytes(data), .list([])]
    }
    private var legacyFields: [RLP] {
        [.number(nonce), .number(maxFee), .number(gasLimit), .bytes((try? Data(strictHex: to)) ?? Data()), .number(value), .bytes(data)]
    }
    public var unsignedSerialized: Data {
        if mode == .legacy { return RLP.list(legacyFields + [.number(BigUInt(chainID)), .number(0), .number(0)]).encoded }
        return Data([2]) + RLP.list(fields).encoded
    }
    public var signingHash: Data { unsignedSerialized.keccak256 }
    /// Size-correct signature placeholders, used only by a fee oracle; never broadcast.
    public var feeEstimationSerialized: Data {
        let placeholder = BigUInt(Data(repeating: 0xff, count: 32))
        if mode == .legacy { return RLP.list(legacyFields + [.number(BigUInt(chainID) * 2 + 36), .number(placeholder), .number(placeholder)]).encoded }
        return Data([2]) + RLP.list(fields + [.number(1), .number(placeholder), .number(placeholder)]).encoded
    }
    public var maximumFee: BigUInt { gasLimit * maxFee }
    func serialized(r: BigUInt, s: BigUInt, recovery: UInt8) throws -> Data {
        guard recovery < 2, r > 0, s > 0, r.bitWidth <= 256, s.bitWidth <= 256 else { throw WalletError.invalid(L("message.invalid_node_transaction_signature_fields")) }
        if mode == .legacy { return RLP.list(legacyFields + [.number(BigUInt(chainID) * 2 + 35 + BigUInt(recovery)), .number(r), .number(s)]).encoded }
        return Data([2]) + RLP.list(fields + [.number(BigUInt(recovery)), .number(r), .number(s)]).encoded
    }
    public func signed(privateKey: Data) throws -> Data {
        let signature = try Secp256k1.sign(hash: signingHash, privateKey: privateKey)
        if mode == .legacy {
            let v = BigUInt(chainID) * 2 + 35 + BigUInt(signature.recovery)
            return RLP.list(legacyFields + [.number(v), .number(BigUInt(signature.r)), .number(BigUInt(signature.s))]).encoded
        }
        return Data([2]) + RLP.list(fields + [.number(BigUInt(signature.recovery)), .number(BigUInt(signature.r)), .number(BigUInt(signature.s))]).encoded
    }
}
