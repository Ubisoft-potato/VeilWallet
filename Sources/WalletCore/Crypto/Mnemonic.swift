import Foundation

public enum Mnemonic {
    public static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()
    public static func normalize(_ phrase: String) -> String {
        phrase.decomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func generate(wordCount: Int = 12) throws -> String {
        guard [12, 24].contains(wordCount) else { throw WalletError.invalid(L("message.generation_supports_12_or_24_words")) }
        return try fromEntropy(Data.secureRandom(count: wordCount == 12 ? 16 : 32))
    }
    public static func fromEntropy(_ entropy: Data) throws -> String {
        guard [16, 20, 24, 28, 32].contains(entropy.count), words.count == 2048 else { throw WalletError.invalid(L("message.invalid_bip39_entropy_or_word_list")) }
        let checksumCount = entropy.count / 4
        let bits = bitArray(entropy) + bitArray(entropy.sha256Digest).prefix(checksumCount)
        return stride(from: 0, to: bits.count, by: 11).map { offset in
            words[bits[offset..<(offset + 11)].reduce(0) { ($0 << 1) | Int($1) }]
        }.joined(separator: " ")
    }
    public static func validate(_ phrase: String) -> Bool {
        let tokens = normalize(phrase).split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(tokens.count), words.count == 2048 else { return false }
        let lookup = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        var bits = [UInt8]()
        for word in tokens {
            guard let index = lookup[word] else { return false }
            bits += (0..<11).reversed().map { UInt8((index >> $0) & 1) }
        }
        let entropyCount = bits.count * 32 / 33
        var entropy = Data()
        for offset in stride(from: 0, to: entropyCount, by: 8) {
            entropy.append(bits[offset..<(offset + 8)].reduce(0) { ($0 << 1) | $1 })
        }
        return Array(bits[entropyCount...]) == Array(bitArray(entropy.sha256Digest).prefix(bits.count - entropyCount))
    }
    public static func seed(phrase: String, passphrase: String = "") throws -> Data {
        guard validate(phrase) else { throw WalletError.invalid(L("message.the_recovery_phrase_contains_invalid_words_or_a_wrong_checksum")) }
        return try KeyDerivation.pbkdf2(password: Data(normalize(phrase).utf8),
            salt: Data(("mnemonic" + passphrase.decomposedStringWithCompatibilityMapping).utf8),
            rounds: 2048, count: 64, sha512: true)
    }
    private static func bitArray(_ data: Data) -> [UInt8] {
        data.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
    }
}
