import Foundation
import BigInt

extension EVMTransaction {
    /// Bounded RLP framing only. All ECDSA recovery uses pinned libsecp256k1.
    /// Re-encoding from the approved transaction binds every field, including
    /// chain, nonce, fees, destination, amount, calldata and empty access list.
    func verifySigned(_ raw: Data, sender: String) throws {
        guard raw.count <= 129_024, !raw.isEmpty, Ethereum.validateAddress(sender) else { throw WalletError.invalid(L("message.invalid_signed_envelope_length_or_sender")) }
        let bytes = Array(raw), begin = mode == .eip1559 ? 1 : 0
        guard mode != .eip1559 || bytes[0] == 2 else { throw WalletError.invalid(L("message.signature_type_does_not_match_the_approved_transaction")) }
        struct Item { let list: Bool; let range: Range<Int>; let next: Int }
        func item(_ offset: Int, limit: Int) throws -> Item {
            guard offset < limit else { throw WalletError.invalid(L("message.truncated_rlp")) }
            let prefix = Int(bytes[offset])
            if prefix < 128 { return Item(list: false, range: offset..<(offset + 1), next: offset + 1) }
            let list = prefix >= 192, marker = list ? 192 : 128, shortLimit = marker + 55
            let start: Int, length: Int
            if prefix <= shortLimit { start = offset + 1; length = prefix - marker }
            else {
                let width = prefix - shortLimit
                guard width <= 4, offset + 1 + width <= limit, bytes[offset + 1] != 0 else { throw WalletError.invalid(L("message.noncanonical_rlp_length_encoding")) }
                var count = 0
                for i in (offset + 1)..<(offset + 1 + width) { count = count * 256 + Int(bytes[i]) }
                guard count >= 56 else { throw WalletError.invalid(L("message.noncanonical_rlp_length_encoding")) }; start = offset + 1 + width; length = count
            }
            guard start <= limit, length <= limit - start else { throw WalletError.invalid(L("message.rlp_length_is_out_of_range")) }
            if !list, length == 1, bytes[start] < 128 { throw WalletError.invalid(L("message.noncanonical_single_byte_rlp_encoding")) }
            return Item(list: list, range: start..<(start + length), next: start + length)
        }
        let root = try item(begin, limit: bytes.count)
        guard root.list, root.next == bytes.count else { throw WalletError.invalid(L("message.transaction_envelope_is_not_a_complete_rlp_list")) }
        var fields: [Item] = [], cursor = root.range.lowerBound
        while cursor < root.range.upperBound {
            guard fields.count < 12 else { throw WalletError.invalid(L("message.too_many_signed_envelope_fields")) }
            let field = try item(cursor, limit: root.range.upperBound); fields.append(field); cursor = field.next
        }
        guard fields.count == (mode == .legacy ? 9 : 12) else { throw WalletError.invalid(L("message.signed_envelope_field_count_does_not_match")) }
        for (index, field) in fields.enumerated() where field.list {
            guard mode == .eip1559, index == 8, field.range.isEmpty else { throw WalletError.invalid(L("message.this_envelope_contains_an_unsupported_access_list_or_nested_list")) }
        }
        func uint(_ field: Item) throws -> BigUInt {
            guard !field.list, field.range.count <= 32 else { throw WalletError.invalid(L("message.signature_integer_is_out_of_range")) }; return BigUInt(Data(bytes[field.range]))
        }
        let v = try uint(fields[fields.count - 3]), r = try uint(fields[fields.count - 2]), s = try uint(fields[fields.count - 1]), recovery: UInt8
        if mode == .legacy {
            let base = BigUInt(chainID) * 2 + 35; guard v == base || v == base + 1 else { throw WalletError.invalid(L("message.eip_155_signing_chain_does_not_match")) }; recovery = UInt8(v - base)
        } else { guard v <= 1 else { throw WalletError.invalid(L("message.invalid_type_2_recovery_bit")) }; recovery = UInt8(v) }
        let order = BigUInt("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", radix: 16)!
        guard s <= order / 2, try serialized(r: r, s: s, recovery: recovery) == raw else { throw WalletError.invalid(L("message.signed_data_does_not_match_the_approved_parameters_or_the")) }
        let pub = try Secp256k1.recoverPublicKey(hash: signingHash, r: ContractABI.word(r), s: ContractABI.word(s), recovery: recovery)
        guard "0x" + Data(pub.dropFirst()).keccak256.suffix(20).hexString == sender.lowercased() else { throw WalletError.invalid(L("message.the_recovered_signing_account_does_not_match_the_sender")) }
    }
}
