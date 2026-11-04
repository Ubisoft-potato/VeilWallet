import Foundation

public enum AssetScanScope: String, Codable, CaseIterable, Sendable {
    case common, all, selected
    public var label: String { switch self { case .common: return L("message.common_networks"); case .all: return L("message.all_configured_networks"); case .selected: return L("message.current_network_only") } }
}
public struct WalletPreferences: Codable, Equatable, Sendable {
    public static let lockIntervals = [1, 5, 10, 15, 30, 60, 120]
    public var autoLockMinutes = 30
    public var autoRefreshAssets = true
    public var refreshMinutes = 5
    public var scanScope: AssetScanScope = .common
    // Optional backing preserves decoding of preferences saved by 0.8.x.
    public var usdPricesEnabled: Bool?
    public var fetchUSDPrices: Bool { get { usdPricesEnabled ?? true } set { usdPricesEnabled = newValue } }
    public init() {}
    public var lockInterval: TimeInterval { Double(Self.lockIntervals.contains(autoLockMinutes) ? autoLockMinutes : 30) * 60 }
    public var refreshInterval: TimeInterval { Double([1, 5, 10, 15].contains(refreshMinutes) ? refreshMinutes : 5) * 60 }
    public func shouldLock(idleSeconds: TimeInterval) -> Bool { idleSeconds.isFinite && idleSeconds >= lockInterval }
}
