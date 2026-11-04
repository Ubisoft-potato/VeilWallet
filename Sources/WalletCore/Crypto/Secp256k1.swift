import Foundation
import libsecp256k1

public enum Secp256k1 {
    private static func context() throws -> OpaquePointer {
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)) else {
            throw WalletError.invalid(L("message.secp256k1_initialization_failed"))
        }
        let entropy = try Data.secureRandom(count: 32)
        let result = entropy.withUnsafeBytes { secp256k1_context_randomize(ctx, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard result == 1 else { secp256k1_context_destroy(ctx); throw WalletError.invalid(L("message.secp256k1_randomization_failed")) }
        return ctx
    }
    public static func publicKey(privateKey: Data, compressed: Bool = true) throws -> Data {
        guard privateKey.count == 32 else { throw WalletError.invalid(L("message.private_keys_must_be_32_bytes")) }
        let ctx = try context(); defer { secp256k1_context_destroy(ctx) }
        var pub = secp256k1_pubkey()
        let valid = privateKey.withUnsafeBytes { secp256k1_ec_pubkey_create(ctx, &pub, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard valid == 1 else { throw WalletError.invalid(L("message.the_private_key_is_outside_the_valid_range")) }
        var output = [UInt8](repeating: 0, count: compressed ? 33 : 65); var size = output.count
        guard secp256k1_ec_pubkey_serialize(ctx, &output, &size, &pub, UInt32(compressed ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED)) == 1 else {
            throw WalletError.invalid(L("message.public_key_serialization_failed"))
        }
        return Data(output)
    }
    static func add(privateKey: Data, tweak: Data) throws -> Data {
        guard privateKey.count == 32, tweak.count == 32 else { throw WalletError.invalid(L("message.invalid_derivation_key_length")) }
        let ctx = try context(); defer { secp256k1_context_destroy(ctx) }
        var output = Array(privateKey)
        let result = tweak.withUnsafeBytes { secp256k1_ec_seckey_tweak_add(ctx, &output, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard result == 1 else { throw WalletError.invalid(L("message.invalid_bip32_child_key_use_the_next_index")) }
        return Data(output)
    }
    static func multiply(privateKey: Data, tweak: Data) throws -> Data {
        guard privateKey.count == 32, tweak.count == 32 else { throw WalletError.invalid(L("message.invalid_mweb_key_length")) }
        let ctx = try context(); defer { secp256k1_context_destroy(ctx) }
        var output = Array(privateKey)
        let result = tweak.withUnsafeBytes { secp256k1_ec_seckey_tweak_mul(ctx, &output, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard result == 1 else { throw WalletError.invalid(L("message.invalid_mweb_scan_or_spend_private_key")) }
        return Data(output)
    }
    public static func sign(hash: Data, privateKey: Data) throws -> (r: Data, s: Data, recovery: UInt8) {
        guard hash.count == 32, privateKey.count == 32 else { throw WalletError.invalid(L("message.invalid_signing_input_length")) }
        let ctx = try context(); defer { secp256k1_context_destroy(ctx) }
        var sig = secp256k1_ecdsa_recoverable_signature()
        let valid = hash.withUnsafeBytes { digest in privateKey.withUnsafeBytes { key in
            secp256k1_ecdsa_sign_recoverable(ctx, &sig, digest.bindMemory(to: UInt8.self).baseAddress!, key.bindMemory(to: UInt8.self).baseAddress!, nil, nil)
        } }
        guard valid == 1 else { throw WalletError.invalid(L("message.signing_failed")) }
        var compact = [UInt8](repeating: 0, count: 64); var recovery: Int32 = 0
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &compact, &recovery, &sig) == 1, recovery < 2 else {
            throw WalletError.invalid(L("message.could_not_encode_the_ethereum_signature_rebuild_the_transaction"))
        }
        return (Data(compact[0..<32]), Data(compact[32..<64]), UInt8(recovery))
    }
    public static func recoverPublicKey(hash: Data, r: Data, s: Data, recovery: UInt8) throws -> Data {
        guard hash.count == 32, r.count == 32, s.count == 32, recovery < 2 else { throw WalletError.invalid(L("message.invalid_public_signature_recovery_parameters")) }
        let ctx = try context(); defer { secp256k1_context_destroy(ctx) }
        var signature = secp256k1_ecdsa_recoverable_signature(), pub = secp256k1_pubkey()
        let compact = r + s
        guard compact.withUnsafeBytes({ secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &signature, $0.bindMemory(to: UInt8.self).baseAddress!, Int32(recovery)) }) == 1,
              hash.withUnsafeBytes({ secp256k1_ecdsa_recover(ctx, &pub, &signature, $0.bindMemory(to: UInt8.self).baseAddress!) }) == 1 else { throw WalletError.invalid(L("message.could_not_recover_the_sender_s_public_key_from_the")) }
        var output = [UInt8](repeating: 0, count: 65), size = 65
        guard secp256k1_ec_pubkey_serialize(ctx, &output, &size, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1 else { throw WalletError.invalid(L("message.recovered_public_key_encoding_failed")) }; return Data(output)
    }
}

public struct HDKey {
    public let privateKey: Data
    public let chainCode: Data
    public init(seed: Data) throws {
        let digest = KeyDerivation.hmac512(key: Data("Bitcoin seed".utf8), data: seed)
        privateKey = Data(digest.prefix(32)); chainCode = Data(digest.suffix(32))
        _ = try Secp256k1.publicKey(privateKey: privateKey)
    }
    private init(privateKey: Data, chainCode: Data) { self.privateKey = privateKey; self.chainCode = chainCode }
    public func child(_ index: UInt32) throws -> HDKey {
        var data = index >= 0x80000000 ? Data([0]) + privateKey : try Secp256k1.publicKey(privateKey: privateKey)
        var bigEndian = index.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        let digest = KeyDerivation.hmac512(key: chainCode, data: data)
        // BIP32 rejects IL >= curve order, not modular reduction.
        return try HDKey(privateKey: Secp256k1.add(privateKey: privateKey, tweak: Data(digest.prefix(32))), chainCode: Data(digest.suffix(32)))
    }
    public func derived(path: String) throws -> HDKey {
        let parts = path.split(separator: "/")
        guard parts.first == "m" else { throw WalletError.invalid(L("message.derivation_paths_must_start_with_m")) }
        return try parts.dropFirst().reduce(self) { key, part in
            let hardened = part.hasSuffix("'")
            let digits = hardened ? part.dropLast() : part[...]
            guard let index = UInt32(digits), index < 0x80000000 else { throw WalletError.invalid(L("message.invalid_derivation_path")) }
            return try key.child(index + (hardened ? 0x80000000 : 0))
        }
    }
}
