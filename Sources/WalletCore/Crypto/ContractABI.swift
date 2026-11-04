import Foundation
import BigInt

/// Canonical, bounded ABI encoding from typed arguments; no opaque calldata input.
public struct ContractInvocation: Codable, Equatable, Sendable {
    public let contract: String
    public let signature: String
    public let arguments: [String]
    public let nativeValue: BigUInt
    public let data: Data
    public init(contract: String, signature: String, arguments: [String], nativeValue: BigUInt = 0) throws {
        guard Ethereum.validateAddress(contract), contract.lowercased() != "0x" + String(repeating: "0", count: 40), nativeValue.bitWidth <= 256 else { throw WalletError.invalid(L("message.invalid_contract_address_or_attached_native_amount")) }
        self.contract = Ethereum.checksumAddress(contract); self.signature = signature; self.arguments = arguments; self.nativeValue = nativeValue
        data = try ContractABI.encode(signature: signature, arguments: arguments)
    }
}

public enum ContractABI {
    private indirect enum Kind {
        case primitive(String), tuple([Kind]), array(Kind), fixedArray(Kind, Int)
        var dynamic: Bool { switch self { case .array: return true; case .fixedArray(let t, _): return t.dynamic; case .tuple(let types): return types.contains { $0.dynamic }; case .primitive(let type): return type == "bytes" || type == "string" } }
        var headSize: Int { if dynamic { return 32 }; switch self { case .tuple(let types): return types.reduce(0) { $0 + $1.headSize }; case .fixedArray(let t, let n): return t.headSize * n; default: return 32 } }
        static func parse(_ text: String, depth: Int = 0) throws -> Kind {
            guard depth <= 6, !text.isEmpty else { throw WalletError.invalid(L("message.abi_type_is_empty_or_nested_too_deeply")) }
            if text.hasSuffix("[]") { return .array(try parse(String(text.dropLast(2)), depth: depth + 1)) }
            if text.hasSuffix("]"), let start = text.lastIndex(of: "[") {
                let size = String(text[text.index(after: start)..<text.index(before: text.endIndex)])
                guard let count = Int(size), (1...64).contains(count), size == String(count) else { throw WalletError.invalid(L("message.invalid_abi_fixed_array_length")) }
                return .fixedArray(try parse(String(text[..<start]), depth: depth + 1), count)
            }
            if text.first == "(", text.last == ")" {
                let fields = try split(String(text.dropFirst().dropLast()))
                guard !fields.isEmpty, fields.count <= 32 else { throw WalletError.invalid(L("message.incorrect_abi_tuple_field_count")) }
                return .tuple(try fields.map { try parse($0, depth: depth + 1) })
            }
            if ["bytes", "string", "address", "bool"].contains(text) { return .primitive(text) }
            for prefix in ["uint", "int"] where text.hasPrefix(prefix) {
                if let bits = Int(text.dropFirst(prefix.count)), (8...256).contains(bits), bits % 8 == 0, text == prefix + String(bits) { return .primitive(text) }
            }
            if text.hasPrefix("bytes"), let count = Int(text.dropFirst(5)), (1...32).contains(count), text == "bytes" + String(count) { return .primitive(text) }
            throw WalletError.invalid(L("message.unsupported_or_noncanonical_abi_type"))
        }
    }
    private static func split(_ text: String) throws -> [String] {
        if text.isEmpty { return [] }; var depth = 0; var current = ""; var fields: [String] = []
        for c in text {
            if c == "(" { depth += 1 }; if c == ")" { depth -= 1 }; guard depth >= 0, depth <= 8 else { throw WalletError.invalid(L("message.invalid_abi_parentheses")) }
            if c == ",", depth == 0 { guard !current.isEmpty else { throw WalletError.invalid(L("message.empty_abi_field")) }; fields.append(current); current = "" } else { current.append(c) }
        }
        guard depth == 0, !current.isEmpty else { throw WalletError.invalid(L("message.invalid_abi_parentheses_or_empty_field")) }; fields.append(current); return fields
    }
    public static func types(_ signature: String) throws -> [String] {
        guard signature.utf8.count <= 512,
              signature.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\([A-Za-z0-9,\[\]\(\)]*\)$"#, options: .regularExpression) != nil,
              let open = signature.firstIndex(of: "(") else { throw WalletError.invalid(L("message.use_a_canonical_function_signature_such_as_transfer_address_uint256")) }
        let fields = signature[signature.index(after: open)..<signature.index(before: signature.endIndex)]
        let result = try split(String(fields))
        guard result.count <= 32 else { throw WalletError.invalid(L("message.too_many_abi_arguments")) }
        for type in result { _ = try Kind.parse(type) }
        return result
    }
    public static func encode(signature: String, arguments: [String]) throws -> Data {
        let types = try types(signature)
        guard types.count == arguments.count, arguments.allSatisfy({ $0.utf8.count <= 16_384 }) else { throw WalletError.invalid(L("message.function_argument_count_or_length_does_not_match")) }
        let output = Data(Data(signature.utf8).keccak256.prefix(4)) + (try sequence(types.map { try Kind.parse($0) }, arguments))
        guard output.count <= 128_000 else { throw WalletError.invalid(L("message.contract_calldata_is_too_long")) }; return output
    }
    public static func json(_ values: [String]) throws -> String { String(decoding: try JSONEncoder().encode(values), as: UTF8.self) }
    public static func parameters(types: [String], arguments: [String]) throws -> Data {
        guard types.count <= 32, arguments.allSatisfy({ $0.utf8.count <= 64_000 }) else { throw WalletError.invalid(L("message.abi_argument_is_too_long")) }
        return try sequence(types.map { try Kind.parse($0) }, arguments)
    }
    private static func sequence(_ types: [Kind], _ values: [String]) throws -> Data {
        guard types.count == values.count else { throw WalletError.invalid(L("message.incorrect_abi_field_count")) }
        let size = types.reduce(0) { $0 + $1.headSize }; var head = Data(), tail = Data()
        for (type, value) in zip(types, values) {
            let encoded = try encode(type: type, value: value)
            if type.dynamic { head += word(BigUInt(size + tail.count)); tail += encoded } else { head += encoded }
            guard head.count + tail.count <= 128_000 else { throw WalletError.invalid(L("message.abi_data_is_too_long")) }
        }
        return head + tail
    }
    private static func encode(type kind: Kind, value: String) throws -> Data {
        switch kind {
        case .array(let element):
            guard let data = value.data(using: .utf8), let elements = try? JSONDecoder().decode([String].self, from: data), elements.count <= 64 else { throw WalletError.invalid(L("message.arrays_must_be_json_string_arrays_with_at_most_64")) }
            return word(BigUInt(elements.count)) + (try sequence(Array(repeating: element, count: elements.count), elements))
        case .fixedArray(let element, let count):
            guard let data = value.data(using: .utf8), let elements = try? JSONDecoder().decode([String].self, from: data), elements.count == count else { throw WalletError.invalid(L("message.abi_fixed_array_item_count_does_not_match")) }
            return try sequence(Array(repeating: element, count: count), elements)
        case .tuple(let types):
            guard let data = value.data(using: .utf8), let fields = try? JSONDecoder().decode([String].self, from: data) else { throw WalletError.invalid(L("message.tuples_must_be_json_string_arrays")) }
            return try sequence(types, fields)
        case .primitive(let type): return try primitive(type: type, value: value)
        }
    }
    private static func primitive(type: String, value: String) throws -> Data {
        if type == "address" {
            guard Ethereum.validateAddress(value) else { throw WalletError.invalid(L("message.abi_address_validation_failed")) }
            return Data(repeating: 0, count: 12) + (try Data(strictHex: value))
        }
        if type == "bool" {
            guard value == "true" || value == "false" else { throw WalletError.invalid(L("message.boolean_arguments_must_be_true_or_false")) }; return word(value == "true" ? 1 : 0)
        }
        if type.hasPrefix("uint"), !type.hasSuffix("[]"), let bits = Int(type.dropFirst(4)) {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let n = BigUInt(value), n.bitWidth <= bits else { throw WalletError.invalid(L("message.unsigned_abi_integer_is_out_of_range_use_a_base")) }; return word(n)
        }
        if type.hasPrefix("int"), let bits = Int(type.dropFirst(3)) {
            let negative = value.hasPrefix("-"); let digits = negative ? String(value.dropFirst()) : value
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let n = BigUInt(digits), negative ? n <= BigUInt(1) << (bits - 1) : n < BigUInt(1) << (bits - 1) else { throw WalletError.invalid(L("message.signed_abi_integer_is_out_of_range")) }
            return word(negative && n > 0 ? (BigUInt(1) << 256) - n : n)
        }
        let raw = try type == "string" ? Data(value.utf8) : Data(strictHex: value)
        if type == "bytes" || type == "string" { return word(BigUInt(raw.count)) + raw + Data(repeating: 0, count: (32 - raw.count % 32) % 32) }
        guard let count = Int(type.dropFirst(5)), raw.count == count else { throw WalletError.invalid(L("message.fixed_size_bytes_argument_has_the_wrong_length")) }
        return raw + Data(repeating: 0, count: 32 - raw.count)
    }
    public static func word(_ value: BigUInt) -> Data {
        let bytes = value.serialize(); return Data(repeating: 0, count: max(0, 32 - bytes.count)) + bytes
    }
    public static func uint(_ data: Data) throws -> BigUInt {
        guard data.count == 32 else { throw WalletError.invalid(L("message.contract_did_not_return_one_uint256")) }; return BigUInt(data)
    }
    public static func uintWords(_ data: Data, count: Int) throws -> [BigUInt] {
        guard count > 0, count <= 64, data.count == count * 32 else { throw WalletError.invalid(L("message.contract_returned_an_invalid_static_field")) }
        return (0..<count).map { BigUInt(data[($0 * 32)..<(($0 + 1) * 32)]) }
    }
    public static func address(_ data: Data) throws -> String {
        guard data.count == 32, data.prefix(12).allSatisfy({ $0 == 0 }) else { throw WalletError.invalid(L("message.contract_did_not_return_one_address")) }
        let result = "0x" + data.suffix(20).hexString
        guard result != "0x" + String(repeating: "0", count: 40) else { throw WalletError.invalid(L("message.contract_returned_the_zero_address")) }; return Ethereum.checksumAddress(result)
    }
    public static func uintArray(_ data: Data, count: Int) throws -> [BigUInt] {
        guard (1...64).contains(count), data.count == (count + 2) * 32, BigUInt(data.prefix(32)) == 32, BigUInt(data[32..<64]) == BigUInt(count) else { throw WalletError.invalid(L("message.contract_returned_an_invalid_integer_array")) }
        return (0..<count).map { BigUInt(data[(64 + $0 * 32)..<(96 + $0 * 32)]) }
    }
    public static func addressArray(_ data: Data) throws -> [String] {
        guard data.count >= 64, let count = Int(exactly: BigUInt(data[32..<64])), (1...64).contains(count) else { throw WalletError.invalid(L("message.invalid_contract_address_array_length")) }
        _ = try uintArray(data, count: count)
        return try (0..<count).map { try address(Data(data[(64 + $0 * 32)..<(96 + $0 * 32)])) }
    }
}
