import AppKit
import SwiftUI
import WalletCore

struct MnemonicInputGrid: View {
    @Binding var draft: MnemonicImportDraft
    @ViewState private var revealed = false
    @ViewState private var focused: Int?
    @ViewState private var inputError: String?
    @ViewState private var pendingCount: Int?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("message.recovery_phrase")).font(.system(size: 12, weight: .medium))
                Spacer()
                Button { revealed.toggle() } label: {
                    Label(L(revealed ? "mnemonic.hide_words" : "mnemonic.show_words"), systemImage: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 11)).padding(.horizontal, 4).frame(minHeight: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.veilAccent).font(.system(size: 11))
                    .interactionFrame("mnemonic.reveal")
            }
            HStack(spacing: 8) {
                Picker(L("message.word_count"), selection: Binding(get: { draft.count }, set: selectCount)) {
                    ForEach(MnemonicImportDraft.supportedCounts, id: \.self) { count in Text(L("mnemonic.word_count", count)).tag(count) }
                }.labelsHidden().frame(width: 136)
                Spacer(minLength: 0)
                Button { paste() } label: { Label(L("mnemonic.paste_phrase"), systemImage: "doc.on.clipboard") }
                IconButton(symbol: "trash", title: L("mnemonic.clear")) { draft.clear(); inputError = nil; focused = 0 }
                    .disabled(draft.filledCount == 0).interactionFrame("mnemonic.clear")
            }
            // Eager rows keep native fields and their Tab order alive while scrolling.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<(draft.count / 3), id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in wordCell(row * 3 + column) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
                Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(draft.filledCount)/\(draft.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }.privacySensitive()
            .confirmationDialog(L("mnemonic.resize_confirmation"), isPresented: Binding(get: { pendingCount != nil }, set: { if !$0 { pendingCount = nil } })) {
                Button(L("mnemonic.resize_confirm"), role: .destructive) {
                    if let count = pendingCount { draft.resize(to: count); focused = nil; inputError = nil }; pendingCount = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in revealed = false; focused = nil }
            .onDisappear { revealed = false; focused = nil; inputError = nil; pendingCount = nil }
    }

    private func wordCell(_ index: Int) -> some View {
        let invalid = draft.invalidPositions.contains(index)
        return HStack(spacing: 8) {
            Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).accessibilityHidden(true)
            MnemonicWordField(index: index, value: draft.words[index], revealed: revealed, focused: focused == index,
                              label: L("message.word_0", index + 1), enabled: isEnabled,
                              onEdit: { edit($0, at: index) }, onFocus: { focused = index },
                              onBlur: { if focused == index { focused = nil } },
                              onMove: { direction in
                                  let next = index + direction
                                  guard draft.words.indices.contains(next) else { return false }
                                  focused = next; return true
                              })
                .id(revealed)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24)
        }.padding(.horizontal, 11).frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(invalid ? Color.orange.opacity(0.8) : focused == index ? .veilFocus : .veilBorder, lineWidth: focused == index ? 1.5 : 1).allowsHitTesting(false))
            .contentShape(Rectangle()).onTapGesture { focused = index }.interactionFrame("mnemonic.cell.\(index)")
    }
    private func selectCount(_ count: Int) {
        guard !draft.wouldDiscardWords(resizingTo: count) else { pendingCount = count; return }
        draft.resize(to: count); focused = nil; inputError = nil
    }
    private func edit(_ text: String, at index: Int) -> String {
        do {
            if let next = try draft.insert(text, at: index) { focused = next }
            else if MnemonicImportDraft.supportedCounts.contains(Mnemonic.normalize(text).split(separator: " ").count) { focused = nil }
            inputError = nil
        } catch { inputError = L("mnemonic.paste_error") }
        return draft.words.indices.contains(index) ? draft.words[index] : ""
    }
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { inputError = L("mnemonic.clipboard_empty"); return }
        do { try draft.insert(text, at: 0, wholePhrase: true); inputError = nil; focused = nil }
        catch { inputError = L("mnemonic.paste_error") }
    }
    private var statusText: String {
        if let inputError { return inputError }
        if !draft.invalidPositions.isEmpty { return L("mnemonic.check_spelling", draft.invalidPositions.map { String($0 + 1) }.joined(separator: ", ")) }
        if draft.isComplete { return L(draft.isValid ? "mnemonic.valid" : "mnemonic.checksum_error") }
        return L("mnemonic.input_hint")
    }
    private var statusColor: Color { inputError != nil || !draft.invalidPositions.isEmpty || (draft.isComplete && !draft.isValid) ? .orange : draft.isValid ? .veilGreen : .secondary }
    private var statusSymbol: String { draft.isValid && inputError == nil ? "checkmark.circle.fill" : statusColor == .orange ? "exclamationmark.circle" : "lock.shield" }
}

/// Native secure editors keep words out of spell checking, correction and completion.
/// Paste is handled from the edit event; the clipboard is never polled.
struct MnemonicWordField: NSViewRepresentable {
    let index: Int
    let value: String
    let revealed: Bool
    let focused: Bool
    let label: String
    let enabled: Bool
    let onEdit: (String) -> String
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onMove: (Int) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = revealed ? NSTextField() : NSSecureTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor; field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != value { field.stringValue = value; field.currentEditor()?.string = value }
        field.isEnabled = enabled; field.setAccessibilityLabel(label)
        field.identifier = NSUserInterfaceItemIdentifier("mnemonic.word.\(index)")
        if focused && enabled && field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, coordinator?.parent.focused == true, coordinator?.parent.enabled == true else { return }
                field.scrollToVisible(field.bounds.insetBy(dx: -12, dy: -16))
                field.window?.makeFirstResponder(field)
            }
        } else if !focused && field.currentEditor() != nil {
            field.window?.makeFirstResponder(nil)
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MnemonicWordField
        init(_ parent: MnemonicWordField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField, let editor = field.currentEditor() as? NSTextView {
                editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticTextCompletionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticDataDetectionEnabled = false
                editor.allowsUndo = false
            }
            parent.onFocus()
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let normalized = parent.onEdit(field.stringValue)
            if normalized != field.stringValue {
                field.stringValue = normalized
                if let editor = field.currentEditor() { editor.string = normalized; editor.selectedRange = NSRange(location: (normalized as NSString).length, length: 0) }
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onBlur() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch NSStringFromSelector(command) {
            case "insertNewline:", "insertTab:": return parent.onMove(1)
            case "insertBacktab:": return parent.onMove(-1)
            case "deleteBackward:": return textView.string.isEmpty && parent.onMove(-1)
            default: return false
            }
        }
    }
}
