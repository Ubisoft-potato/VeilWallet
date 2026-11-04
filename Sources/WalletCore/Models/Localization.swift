import Foundation
import Observation

/// Language identifiers are stable; names and message text come from bundled configuration.
public enum WalletLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    public static let preferenceKey = "VeilWallet.interfaceLanguage"
    public static var current: WalletLanguage { WalletLocalization.preferences.language }
    public var name: String { WalletLocalization.configuration.languages.first { $0.id == rawValue }?.nativeName ?? rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    @MainActor public static func select(_ language: WalletLanguage) { WalletLocalization.preferences.select(language) }
}

/// Explicit registration makes transitive L(...) reads observable inside SwiftUI bodies.
/// Access is locked; mutations/notifications occur on the main actor, outside the read lock.
public final class WalletLanguagePreferences: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var value: WalletLanguage
    private let persist: (@Sendable (String) -> Void)?
    public init(initialRawValue: String?, persist: (@Sendable (String) -> Void)? = nil) {
        value = initialRawValue.flatMap(WalletLanguage.init(rawValue:)) ?? WalletLocalization.defaultLanguage
        self.persist = persist
    }
    public var language: WalletLanguage {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { value }
    }
    @MainActor public func select(_ language: WalletLanguage) {
        guard language != self.language else { return }
        persist?(language.rawValue)
        registrar.withMutation(of: self, keyPath: \.language) { lock.withLock { value = language } }
    }
}

public enum WalletLocalization {
    struct Configuration: Decodable {
        struct Language: Decodable { let id: String; let nativeName: String }
        let defaultLanguage: String
        let languages: [Language]
        let aliases: [String: String]
        let legacyValues: [String: String]
    }
    static let configuration: Configuration = {
        guard let url = Bundle.module.url(forResource: "i18n", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data) else {
            preconditionFailure("Missing bundled i18n configuration")
        }
        return configuration
    }()
    public static var defaultLanguage: WalletLanguage { WalletLanguage(rawValue: configuration.defaultLanguage) ?? .english }
    private static let devicePreferences = WalletLanguagePreferences(
        initialRawValue: UserDefaults.standard.string(forKey: WalletLanguage.preferenceKey),
        persist: { UserDefaults.standard.set($0, forKey: WalletLanguage.preferenceKey) })
    #if DEBUG
    private static let verificationLock = NSLock()
    private static var verificationPreferences: WalletLanguagePreferences?
    /// A fresh process can exercise the real language control without modifying user preferences.
    @MainActor public static func useInMemoryLanguagePreferencesForVerification(_ initial: WalletLanguage) {
        verificationLock.withLock { verificationPreferences = WalletLanguagePreferences(initialRawValue: initial.rawValue) }
    }
    #endif
    public static var preferences: WalletLanguagePreferences {
        #if DEBUG
        if let value = verificationLock.withLock({ verificationPreferences }) { return value }
        #endif
        return devicePreferences
    }
    static let marker = try! NSRegularExpression(pattern: "⟦([0-9]+)⟧")
    private static let catalogs: [WalletLanguage: [String: String]] = Dictionary(uniqueKeysWithValues: WalletLanguage.allCases.map { language in
        guard let directory = Bundle.module.url(forResource: language.rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: directory),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            preconditionFailure("Missing bundled language catalog")
        }
        return (language, values)
    })
    public static func catalog(_ language: WalletLanguage) -> [String: String] { catalogs[language] ?? [:] }

    public static func text(_ key: String, arguments: [String] = [], language: WalletLanguage = .current) -> String {
        if let template = catalogs[language]?[key], let result = render(template, arguments: arguments) { return result }
        if let template = catalogs[defaultLanguage]?[key], let result = render(template, arguments: arguments) { return result }
        return key
    }
    /// Application-owned catalog labels may arrive from older versions in either language.
    public static func key(_ label: String, language: WalletLanguage = .current) -> String {
        let key = catalogs[defaultLanguage]?[label] != nil ? label : configuration.aliases[label]
        return key.map { text($0, language: language) } ?? label
    }
    /// Canonical values used by old persisted transaction records, never selected by UI language.
    public static func legacy(_ key: String) -> String { configuration.legacyValues[key] ?? key }

    private struct StoredTemplate {
        let regex: NSRegularExpression
        let key: String
        let argumentIndexes: [Int]
        let specificity: Int
    }
    private static let storedTemplates: [StoredTemplate] = catalogs.flatMap { _, values in values.compactMap { key, template -> StoredTemplate? in
        let ns = template as NSString
        let matches = marker.matches(in: template, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var pattern = "\\A"; var end = 0
        for match in matches {
            pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: end, length: match.range.location - end))) + "(.*?)"
            end = NSMaxRange(match.range)
        }
        pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: end)) + "\\z"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
        return StoredTemplate(regex: regex, key: key,
                              argumentIndexes: matches.compactMap { Int(ns.substring(with: $0.range(at: 1))) },
                              specificity: template.count - matches.reduce(0) { $0 + $1.range.length })
    }}.sorted { $0.specificity == $1.specificity ? $0.key < $1.key : $0.specificity > $1.specificity }

    /// Display-only compatibility for app-generated cached descriptions, never user names or parsing.
    public static func stored(_ message: String, language: WalletLanguage = .current) -> String {
        if let key = configuration.aliases[message], !(catalogs[language]?[key]?.contains("⟦") ?? true) {
            return text(key, language: language)
        }
        guard message.utf8.count <= 16_384 else { return message }
        let ns = message as NSString
        for template in storedTemplates {
            guard let match = template.regex.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)),
                  template.argumentIndexes.sorted() == Array(0..<template.argumentIndexes.count) else { continue }
            var arguments = Array(repeating: "", count: template.argumentIndexes.count)
            for (group, index) in template.argumentIndexes.enumerated() { arguments[index] = ns.substring(with: match.range(at: group + 1)) }
            return text(template.key, arguments: arguments, language: language)
        }
        return message
    }
    /// Values are appended once and never interpreted as format strings or additional placeholders.
    static func render(_ template: String, arguments: [String]) -> String? {
        let ns = template as NSString
        let matches = marker.matches(in: template, range: NSRange(location: 0, length: ns.length))
        let indexes = matches.compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        guard indexes.sorted() == Array(arguments.indices) else { return nil }
        var output = ""; var end = 0
        for (match, index) in zip(matches, indexes) {
            output += ns.substring(with: NSRange(location: end, length: match.range.location - end))
            output += arguments[index]; end = NSMaxRange(match.range)
        }
        return output + ns.substring(from: end)
    }
}

public func L(_ key: String, _ arguments: Any...) -> String {
    WalletLocalization.text(key, arguments: arguments.map { String(describing: $0) })
}
public func LK(_ label: String) -> String { WalletLocalization.key(label) }
public func LS(_ message: String) -> String { WalletLocalization.stored(message) }
