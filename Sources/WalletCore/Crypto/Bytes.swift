import Foundation
import CryptoKit
import CryptoSwift
import Security
import CPrivacyTransport

public enum WalletError: Error, LocalizedError, Equatable {
    case invalid(String)
    case locked
    case networkBlocked
    case transport(Int)
    case http(Int)
    case rpc(String)
    case rpcRejected(Int)
    case vaultAuthentication
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .locked: return L("message.wallet_is_locked")
        case .networkBlocked: return L("message.tor_is_not_ready_network_requests_are_blocked")
        case .transport(let code): return L("message.tor_request_failed_0_no_direct_fallback_was_used", code)
        case .http(let code): return L("message.request_through_tor_failed_http_0", code)
        case .rpc(let text): return L("message.node_returned_an_error_0", text)
        case .rpcRejected(let code): return L("message.node_rejected_the_rpc_request_0_check_the_endpoint_or", code)
        case .vaultAuthentication: return L("message.incorrect_password_or_damaged_vault_data")
        }
    }
}

public extension Data {
    init(strictHex: String) throws {
        let value = strictHex.hasPrefix("0x") ? String(strictHex.dropFirst(2)) : strictHex
        guard value.count % 2 == 0, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw WalletError.invalid(L("message.invalid_hexadecimal_data"))
        }
        var data = Data(); var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { throw WalletError.invalid(L("message.invalid_hexadecimal_data")) }
            data.append(byte); index = end
        }
        self = data
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    var keccak256: Data { Data(CryptoSwift.SHA3(variant: .keccak256).calculate(for: Array(self))) }
    var sha256Digest: Data { Data(CryptoKit.SHA256.hash(data: self)) }
    static func secureRandom(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw WalletError.invalid(L("message.secure_random_generation_failed")) }
        return data
    }
}

public enum KeyDerivation {
    public static func pbkdf2(password: Data, salt: Data, rounds: UInt32, count: Int, sha512: Bool = false) throws -> Data {
        var output = Data(count: count)
        let status = output.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pass in
                salt.withUnsafeBytes { salt in
                    veil_pbkdf2(pass.bindMemory(to: UInt8.self).baseAddress, password.count,
                        salt.bindMemory(to: UInt8.self).baseAddress, salt.count, rounds,
                        sha512 ? 1 : 0, out.bindMemory(to: UInt8.self).baseAddress, count)
                }
            }
        }
        guard status == 0 else { throw WalletError.invalid(L("message.key_derivation_failed")) }
        return output
    }
    static func hmac512(key: Data, data: Data) -> Data {
        Data(CryptoKit.HMAC<CryptoKit.SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
