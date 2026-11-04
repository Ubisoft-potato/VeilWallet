import Foundation

public enum EVMFeeModel: String, Sendable {
    case standard, opStack, mantle, scroll, executionOnly, unavailable
    public var label: String {
        switch self {
        case .standard: return "EVM Gas"
        case .opStack: return L("message.op_stack_l1_operator_fees")
        case .mantle: return L("message.mantle_arsia_fees")
        case .scroll: return L("message.scroll_l1_data_fees")
        case .executionOnly: return L("message.execution_fee_estimate_only")
        case .unavailable: return L("message.fee_model_unsupported")
        }
    }
}
public enum EVMNetworkSupport {
    // EraVM accepts standard EIP-155 transfers and has no priority-fee market.
    // Use its gasPrice quote instead of depending on optional priority-fee RPC support.
    public static let legacyFeeChainIDs: Set<UInt64> = [324, 2741]
    // A local product selection, not a ranking or an automatically downloaded chain list.
    public static let mainstreamIDs: [UInt64] = [
        1, 56, 137, 42161, 10, 8453, 43114, 146, 100, 25, 250, 42220, 8217,
        1329, 80094, 999, 143, 59144, 534352, 324, 5000, 81457, 7777777, 130,
        196, 204, 169, 1088, 1284, 1285, 1313161554, 30, 2020, 33139, 747474,
        57073, 9745, 42170, 2741, 480, 1868, 1135, 2818, 43111, 48900, 252,
        13371, 592, 4689, 40, 7000, 50, 14, 314, 1666600000, 369
    ]
    public static func feeModel(chainID: UInt64) -> EVMFeeModel {
        if [4217, 5042].contains(chainID) { return .unavailable }
        if [10, 8453, 7777777, 81457, 34443, 130, 57073, 480, 1868, 1135, 48900, 252, 4326, 60808, 204].contains(chainID) { return .opStack }
        if chainID == 534352 { return .scroll }
        if chainID == 5000 { return .mantle }
        // These rollups use custom/older DA fee rules; the UI does not call the execution estimate a total.
        if [169, 1088, 288, 200901, 4200, 42766, 167000, 2818, 43111].contains(chainID) { return .executionOnly }
        return .standard
    }
    public static func rank(_ chain: Chain) -> Int {
        mainstreamIDs.firstIndex(of: chain.id) ?? Int.max
    }
    public static let expectedGenesisHashes: [UInt64: String] = [
        // ETHW and smartBCH testnet share chain ID 10001; chain ID alone cannot distinguish them.
        10001: "0xd4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
    ]
    public static let previousDefaultRPCs: [UInt64: Set<String>] = [
        1: ["https://ethereum-rpc.publicnode.com"],
        10001: ["https://rpc-testnet.smartbch.org"],
        42220: ["https://forno.celo.org"],
        250: ["https://rpc.ftm.tools"],
        314: ["https://api.node.glif.io/"],
        100: ["https://rpc.gnosischain.com"],
        57073: ["https://rpc-gel.inkonchain.com"],
        1135: ["https://rpc.api.lisk.com"],
        1284: ["https://rpc.api.moonbeam.network"],
        1285: ["https://rpc.api.moonriver.moonbeam.network"],
        2741: ["https://api.mainnet.abs.xyz"],
        324: ["https://mainnet.era.zksync.io"],
        50: ["https://erpc.xinfin.network"]
    ]
}
public extension Chain {
    var isMainstreamEVM: Bool { isEVM && EVMNetworkSupport.mainstreamIDs.contains(id) }
    var evmFeeModel: EVMFeeModel { isEVM ? EVMNetworkSupport.feeModel(chainID: id) : .unavailable }
    var feeNotice: String? {
        guard isEVM else { return nil }
        switch evmFeeModel {
        case .executionOnly: return L("message.only_execution_fees_are_estimated_this_network_s_extra_data")
        case .unavailable: return L("message.this_network_s_native_asset_or_fee_model_is_unsupported")
        default: return nil
        }
    }
}
