import Foundation

public enum TronAddress {
    public static let chainID: UInt64 = 0x8000000000000000 | 195
    public static func validate(_ value: String) -> Bool { (try? evm(value)) != nil }
    public static func evm(_ value: String) throws -> String {
        // Reuse the pinned upstream Base58Check decoder via the offline ABI.
        let profile = AccountProfile.find("tron")!
        guard let raw = try MultichainCrypto.execute(.init(action: "tronAddress", profile: profile, address: value)).key else { throw WalletError.invalid(L("message.invalid_tron_mainnet_address")) }
        return "0x" + raw
    }
    public static func base58(_ value: String) throws -> String {
        guard Ethereum.validateAddress(value), let address = try MultichainCrypto.execute(.init(action: "tronAddress", profile: AccountProfile.find("tron")!, address: value)).address else { throw WalletError.invalid(L("message.invalid_tvm_address")) }
        return address
    }
    static func fromRPC(_ value: String?) throws -> String {
        guard let value else { throw WalletError.invalid(L("message.tron_receipt_is_missing_an_address")) }
        if validate(value) { return value }
        let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard hex.count == 42, hex.lowercased().hasPrefix("41") else { throw WalletError.invalid(L("message.tron_receipt_address_is_not_mainnet_format")) }
        return try base58("0x" + hex.dropFirst(2))
    }
}
