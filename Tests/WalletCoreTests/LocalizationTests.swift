import Foundation
import Observation
import Testing
@testable import WalletCore

private final class LanguageChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

struct LocalizationTests {
    @Test func bundledNativeCatalogsHaveMatchingKeysAndPlaceholders() {
        let english = WalletLocalization.catalog(.english), chinese = WalletLocalization.catalog(.simplifiedChinese)
        #expect(english.count >= 1600)
        #expect(Set(english.keys) == Set(chinese.keys))
        for (key, value) in english {
            let count = WalletLocalization.marker.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value))
            let arguments = (0..<count).map { "value-\($0)" }
            #expect(WalletLocalization.render(value, arguments: arguments) != nil)
            #expect(WalletLocalization.render(chinese[key]!, arguments: arguments) != nil)
            if key != "language.simplified_chinese" { #expect(value.range(of: "[\\u3400-\\u9fff]", options: .regularExpression) == nil) }
        }
        #expect(WalletLocalization.text("wallet.lock", language: .english) == "Lock wallet")
        #expect(WalletLocalization.text("wallet.lock", language: .simplifiedChinese) == "锁定钱包")
        #expect(WalletLocalization.text("unknown.key", language: .english) == "unknown.key")
    }
    @Test func translatedValuesRemainOpaqueInBothDirections() {
        let address = "user value ⟦1⟧ %s \" 中文"
        let key = WalletLocalization.configuration.aliases["找零返回所选地址：⟦0⟧ ⟦1⟧"]!
        #expect(WalletLocalization.text(key, arguments: [address, "LTC"], language: .english) == "Change returns to the selected address: \(address) LTC")
        #expect(WalletLocalization.text(key, arguments: [address, "LTC"], language: .simplifiedChinese) == "找零返回所选地址：\(address) LTC")
        #expect(WalletLocalization.render("⟦1⟧ / ⟦0⟧", arguments: ["⟦1⟧", "%@中文"]) == "%@中文 / ⟦1⟧")
        for template in ["⟦0⟧ ⟦0⟧", "⟦1⟧", "missing", "⟦99999999999999999999999999⟧"] {
            #expect(WalletLocalization.render(template, arguments: ["value"]) == nil)
        }
    }
    @MainActor @Test func selectingLanguageNotifiesLiveReadersAndPersistsWithoutRestart() {
        let persisted = LanguageChanges(), notifications = LanguageChanges()
        let preferences = WalletLanguagePreferences(initialRawValue: "en", persist: { persisted.append($0) })
        withObservationTracking { _ = preferences.language } onChange: { notifications.append("changed") }
        preferences.select(.simplifiedChinese)
        #expect(preferences.language == .simplifiedChinese)
        #expect(persisted.values == ["zh-Hans"])
        #expect(notifications.values.count == 1)
        // A new reader sees the current value, not the process's initial language.
        withObservationTracking { _ = preferences.language } onChange: { notifications.append("changed") }
        preferences.select(.english)
        #expect(preferences.language == .english)
        #expect(persisted.values == ["zh-Hans","en"])
        #expect(notifications.values.count == 2)
        preferences.select(.english)
        #expect(persisted.values.count == 2)
        #expect(WalletLanguagePreferences(initialRawValue: persisted.values.last).language == .english)
        #expect(WalletLanguagePreferences(initialRawValue: "unsupported").language == .english)
    }
    @Test func legacyValuesAndCachedDescriptionsRemainCompatibleAcrossLanguages() throws {
        #expect(TransactionPhase.confirmed.label == "已确认")
        var item = Activity(walletID: UUID(), chainID: 1, hash: "public test hash", to: "public fixture", amount: "1", symbol: "ETH")
        item.status = "已确认"
        #expect(!item.isUnresolved)
        #expect(WalletLocalization.key(item.status, language: .english) == "Confirmed")
        #expect(WalletLocalization.stored("Tor 连接中 · 42%", language: .english) == "Connecting to Tor · 42%")
        #expect(WalletLocalization.stored("Connecting to Tor · 42%", language: .simplifiedChinese) == "Tor 连接中 · 42%")
        #expect(WalletLocalization.stored("unrecognized legacy message", language: .simplifiedChinese) == "unrecognized legacy message")
        let profile = AccountProfile.find("monero.ledger")!
        let data = try JSONEncoder().encode(profile)
        let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let nameKey = fields["name"] as! String
        #expect(WalletLocalization.catalog(.english)[nameKey] != nil)
        #expect(WalletLocalization.catalog(.simplifiedChinese)[nameKey] != nil)
        #expect(try JSONDecoder().decode(AccountProfile.self, from: data) == profile)
    }
}
