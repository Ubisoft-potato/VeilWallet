import SwiftUI
import WalletCore

struct WalletExperienceSettings: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                Label(L("message.auto_lock_and_asset_updates"), systemImage: "lock.clock").font(.system(size: 17, weight: .medium))
                HStack {
                    Label(L("message.lock_after_inactivity"), systemImage: "lock.clock")
                    Spacer()
                    Picker(L("message.lock_timeout"), selection: Binding(get: { model.preferences.autoLockMinutes }, set: { minutes in Task { await model.setPreferences { $0.autoLockMinutes = minutes } } })) {
                        ForEach(WalletPreferences.lockIntervals, id: \.self) { minutes in Text(L("message.0_minutes", minutes)).tag(minutes) }
                    }.labelsHidden().frame(width: 160)
                }
                Text(L("message.default_30_minutes_switching_apps_does_not_lock_immediately_user")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Divider()
                Toggle(L("message.discover_and_refresh_assets_automatically_after_unlock_and_tor_connection"), isOn: Binding(get: { model.preferences.autoRefreshAssets }, set: { value in Task { await model.setPreferences { $0.autoRefreshAssets = value } } }))
                HStack {
                    Picker(L("message.query_scope"), selection: Binding(get: { model.preferences.scanScope }, set: { value in Task { await model.setPreferences { $0.scanScope = value } } })) { ForEach(AssetScanScope.allCases, id: \.self) { scope in Text(scope.label).tag(scope) } }
                    Picker(L("message.refresh_interval"), selection: Binding(get: { model.preferences.refreshMinutes }, set: { value in Task { await model.setPreferences { $0.refreshMinutes = value } } })) { ForEach([1, 5, 10, 15], id: \.self) { value in Text(L("message.0_minutes", value)).tag(value) } }
                }
                Text(L("message.queries_native_assets_and_bundled_or_manually_added_tokens_showing")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Divider()
                Toggle(L("message.fetch_usd_prices_via_tor"), isOn: Binding(get: { model.preferences.fetchUSDPrices }, set: { value in Task { await model.setPreferences { $0.fetchUSDPrices = value } } }))
                Text(L("message.defillama_prices_refresh_every_5_minutes_bundled_assets_use_a")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }.disabled(model.busy)
        }
    }
}
