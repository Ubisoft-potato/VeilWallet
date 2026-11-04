import Foundation
import Testing
@testable import WalletCore

struct MnemonicImportTests {
    @Test func completePasteDetectsEveryBIP39LengthAndNormalizesWhitespace() throws {
        for bytes in [16, 20, 24, 28, 32] {
            let phrase = try Mnemonic.fromEntropy(Data(repeating: 0, count: bytes))
            let pasted = phrase.uppercased().components(separatedBy: " ").joined(separator: "\u{3000}\n\t")
            var draft = MnemonicImportDraft()
            try draft.insert(pasted, at: 5)
            #expect(draft.count == bytes * 3 / 4)
            #expect(draft.isComplete && draft.isValid)
            #expect(draft.phrase == phrase)
        }
    }
    @Test func invalidPasteDoesNotReplaceOrTruncateExistingWords() throws {
        var draft = MnemonicImportDraft()
        try draft.insert(Mnemonic.words[0], at: 0)
        let original = draft
        #expect(throws: MnemonicImportDraft.InputError.self) {
            try draft.insert(Array(repeating: Mnemonic.words[0], count: 13).joined(separator: " "), at: 0, wholePhrase: true)
        }
        #expect(draft == original)
        #expect(throws: MnemonicImportDraft.InputError.self) {
            try draft.insert(Array(repeating: Mnemonic.words[0], count: 25).joined(separator: " "), at: 0)
        }
        #expect(draft == original)
        #expect(throws: MnemonicImportDraft.InputError.self) { try draft.insert("one two three", at: 11) }
        #expect(draft == original)
        #expect(throws: MnemonicImportDraft.InputError.self) { try draft.insert("", at: -1) }
        #expect(draft == original)
    }
    @Test func partialPastesAndWhitespaceAdvanceWithoutMovingOtherWords() throws {
        var draft = MnemonicImportDraft()
        let first = Mnemonic.words[0], second = Mnemonic.words[1]
        #expect(try draft.insert(first.uppercased(), at: 2) == nil)
        #expect(try draft.insert(first + " ", at: 2) == 3)
        #expect(try draft.insert(first + "\n" + second, at: 7) == 9)
        #expect(draft.words[2] == first && draft.words[7] == first && draft.words[8] == second)
        #expect(draft.words[0].isEmpty && draft.words[9].isEmpty)
        #expect(try draft.insert(first + " ", at: 11) == nil)
        try draft.insert("", at: 2)
        #expect(draft.words[2].isEmpty)
    }
    @Test func missingWordsCannotCollapseIntoAnotherValidLength() throws {
        let phrase = try Mnemonic.fromEntropy(Data(repeating: 0, count: 16))
        var draft = MnemonicImportDraft()
        try draft.insert(phrase, at: 0)
        draft.resize(to: 24)
        // Joining and normalizing the nonempty prefix would still be a valid 12-word phrase.
        #expect(Mnemonic.validate(draft.phrase))
        #expect(!draft.isComplete && !draft.isValid && draft.filledCount == 12)
        #expect(!draft.wouldDiscardWords(resizingTo: 12))
        try draft.insert(Mnemonic.words[0], at: 23)
        #expect(draft.wouldDiscardWords(resizingTo: 12))
        draft.clear()
        #expect(draft.count == 24 && draft.filledCount == 0 && !draft.isValid)
        draft.resize(to: 12)
        #expect(draft.count == 12 && draft.words.allSatisfy(\.isEmpty))
    }
    @Test func spellingAndChecksumFailuresAreDistinct() throws {
        var draft = MnemonicImportDraft()
        try draft.insert(Array(repeating: Mnemonic.words[0], count: 12).joined(separator: " "), at: 0)
        #expect(draft.isComplete && draft.invalidPositions.isEmpty && !draft.isValid)
        try draft.insert("not-a-bip39-word", at: 6)
        #expect(draft.invalidPositions == [6] && !draft.isValid)
        let phrase = try Mnemonic.fromEntropy(Data(repeating: 0, count: 16))
        try draft.insert(phrase, at: 11, wholePhrase: true)
        #expect(draft.isValid && draft.invalidPositions.isEmpty)
    }
}
