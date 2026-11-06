import AppKit
import SwiftUI
import WalletCore

struct ClipboardCopyButton: View {
    let text: String
    let title: String
    var iconOnly = false
    var pasteboard: NSPasteboard = .general
    @ViewState private var feedback: Feedback?

    private struct Feedback {
        let id = UUID()
        let succeeded: Bool

        var title: String { succeeded ? L("clipboard.copied") : L("clipboard.copy_failed") }
        var symbol: String { succeeded ? "checkmark" : "exclamationmark.circle" }
    }

    var body: some View {
        let feedbackID = feedback?.id
        Group {
            if iconOnly {
                IconButton(symbol: feedback?.symbol ?? "doc.on.doc", title: feedback?.title ?? title, action: copy)
                    .overlay(alignment: .topTrailing) {
                        if let feedback {
                            Text(feedback.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(feedback.succeeded ? Color.veilGreen : .orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.veilControl, in: Capsule())
                                .fixedSize()
                                .offset(y: -24)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            } else {
                Button(action: copy) {
                    if let feedback {
                        Label(feedback.title, systemImage: feedback.symbol)
                    } else {
                        Text(title)
                    }
                }
            }
        }
        .i18nLabel("clipboard.feedback", feedback?.title ?? "")
        .task(id: feedbackID) {
            guard let feedbackID else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, feedback?.id == feedbackID else { return }
            feedback = nil
        }
        .onChange(of: text) { feedback = nil }
        .onDisappear { feedback = nil }
    }

    private func copy() {
        guard !text.isEmpty else {
            feedback = Feedback(succeeded: false)
            return
        }
        pasteboard.clearContents()
        let succeeded = pasteboard.setString(text, forType: .string)
        feedback = Feedback(succeeded: succeeded)
        guard succeeded else { return }

        let change = pasteboard.changeCount
        Task { [pasteboard, change] in
            try? await Task.sleep(for: .seconds(30))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }
}
