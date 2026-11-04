import Foundation

/// Ephemeral input only. Validation and derivation still use Mnemonic's BIP39 implementation.
public struct MnemonicImportDraft: Equatable {
    public static let supportedCounts = [12, 24, 15, 18, 21]
    private static let vocabulary = Set(Mnemonic.words)
    public private(set) var words: [String]
    public var count: Int { words.count }
    public var filledCount: Int { words.filter { !$0.isEmpty }.count }
    public var invalidPositions: [Int] { words.indices.filter { !words[$0].isEmpty && !Self.vocabulary.contains(words[$0]) } }
    public var isComplete: Bool { filledCount == count }
    public var phrase: String { words.joined(separator: " ") }
    public var isValid: Bool { isComplete && invalidPositions.isEmpty && Mnemonic.validate(phrase) }

    public enum InputError: Error { case unsupportedCount, overflow }

    public init(count: Int = 12) {
        words = Array(repeating: "", count: Self.supportedCounts.contains(count) ? count : 12)
    }
    public func wouldDiscardWords(resizingTo count: Int) -> Bool {
        count < words.count && count >= 0 && words.dropFirst(count).contains { !$0.isEmpty }
    }
    public mutating func resize(to count: Int) {
        guard Self.supportedCounts.contains(count) else { return }
        words = Array(words.prefix(count)) + Array(repeating: "", count: max(0, count - words.count))
    }
    public mutating func clear() { words = Array(repeating: "", count: count) }

    /// A complete phrase replaces the draft regardless of which cell receives it.
    /// Shorter multiword pastes fill from the selected cell. Never truncate input.
    @discardableResult public mutating func insert(_ text: String, at index: Int, wholePhrase: Bool = false) throws -> Int? {
        guard words.indices.contains(index) else { throw InputError.overflow }
        let normalized = Mnemonic.normalize(text)
        let tokens = normalized.split(separator: " ").map(String.init)
        if wholePhrase {
            guard Self.supportedCounts.contains(tokens.count) else { throw InputError.unsupportedCount }
            words = tokens
            return nil
        }
        if Self.supportedCounts.contains(tokens.count) {
            words = tokens
            return nil
        }
        guard tokens.count <= 24 else { throw InputError.unsupportedCount }
        guard index + tokens.count <= count else { throw InputError.overflow }
        if tokens.isEmpty { words[index] = ""; return nil }
        for (offset, word) in tokens.enumerated() { words[index + offset] = word }
        let advances = tokens.count > 1 || text.last?.isWhitespace == true
        return advances && index + tokens.count < count ? index + tokens.count : nil
    }
}
