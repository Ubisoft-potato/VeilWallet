import WalletCore
import SwiftUI

extension Color {
    static let veilBackground = Color(red: 0.043, green: 0.047, blue: 0.063)
    static let veilPanel = Color(red: 0.073, green: 0.078, blue: 0.098)
    static let veilBorder = Color(red: 0.14, green: 0.145, blue: 0.18)
    static let veilAccent = Color(red: 0.72, green: 0.67, blue: 1)
    static let veilGreen = Color(red: 0.54, green: 0.88, blue: 0.70)
    static let veilControl = Color(red: 0.095, green: 0.10, blue: 0.13)
    static let veilHover = Color(red: 0.125, green: 0.115, blue: 0.175)
    static let veilPressed = Color(red: 0.19, green: 0.16, blue: 0.27)
    static let veilSelection = Color(red: 0.135, green: 0.12, blue: 0.19)
    static let veilSelectionHover = Color(red: 0.175, green: 0.15, blue: 0.245)
    static let veilSelectionBorder = Color(red: 0.29, green: 0.25, blue: 0.43)
    static let veilHoverBorder = Color(red: 0.38, green: 0.33, blue: 0.55)
    static let veilFocus = Color(red: 0.81, green: 0.76, blue: 1)
}
struct Panel<Content: View>: View {
    var padding: CGFloat = 24
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.veilPanel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.veilBorder).allowsHitTesting(false))
    }
}
struct Pill: View {
    let text: String
    var color: Color = .veilAccent
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.17)))
    }
}
struct PrimaryButton: ButtonStyle {
    var bodyColor: Color = .veilAccent
    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(kind: .primary, pressed: configuration.isPressed, cornerRadius: 11, primaryColor: bodyColor) {
            configuration.label.font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.veilBackground).padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 44)
        }
    }
}

/// Apply the hit shape after the label's padding and frame, so the full visible
/// row (including whitespace) participates in pointer and keyboard activation.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var filled = false
    var cornerRadius: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(kind: .row, pressed: configuration.isPressed, selected: selected, filled: filled, cornerRadius: cornerRadius) { configuration.label }
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(kind: .secondary, pressed: configuration.isPressed, cornerRadius: 10) {
            configuration.label.font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 40)
        }
    }
}

private enum ButtonSurfaceKind { case row, secondary, primary }

/// Hover state belongs to this persistent View, rather than the ButtonStyle
/// value that SwiftUI recreates when its configuration or parent changes.
private struct ButtonSurface<Content: View>: View {
    let kind: ButtonSurfaceKind
    let pressed: Bool
    var selected = false
    var filled = false
    var cornerRadius: CGFloat = 12
    var primaryColor: Color = .veilAccent
    @ViewBuilder var content: Content
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    private var highlighted: Bool { hovered && isEnabled }
    private var hoverAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: hovered ? 0.18 : 0.24) }
    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius).fill(fillColor)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(kind == .primary && isEnabled ? (pressed ? 0.18 : (highlighted ? 0.06 : 0)) : 0)))
                    .animation(hoverAnimation, value: hovered)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selected)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius).stroke(borderColor, lineWidth: isFocused ? 2 : 1)
                    .animation(hoverAnimation, value: hovered)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selected)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onContinuousHover { phase in
                switch phase {
                case .active: setHovered(true)
                case .ended: setHovered(false)
                }
            }
            .observeHoverProbe(setHovered)
    }
    private func setHovered(_ inside: Bool) { if inside != hovered { hovered = inside } }
    private var fillColor: Color {
        if kind == .primary { return primaryColor }
        if pressed && isEnabled { return .veilPressed }
        if selected { return highlighted ? .veilSelectionHover : .veilSelection }
        if highlighted { return .veilHover }
        return kind == .secondary ? .veilControl : (filled ? .veilPanel : .clear)
    }
    private var borderColor: Color {
        if isFocused { return .veilFocus }
        if kind == .primary { return .clear }
        if highlighted { return .veilHoverBorder }
        if selected { return .veilSelectionBorder }
        return kind == .secondary || filled ? .veilBorder : .clear
    }
}

/// Action groups wrap at the actual available width instead of compressing
/// their labels or pushing controls beyond the window's trailing edge.
struct ActionFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return arrangement(width: width, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, rect) in zip(subviews, arrangement(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(0, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}

struct IconButton: View {
    let symbol: String
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(filled: true, cornerRadius: 10))
            .accessibilityLabel(title).help(title)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: selected ? .semibold : .regular)).frame(width: 24)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 8)
                RoundedRectangle(cornerRadius: 2).fill(selected ? Color.veilAccent : .clear).frame(width: 3, height: 18)
            }.foregroundStyle(selected ? Color.veilAccent : Color.primary.opacity(0.72))
                .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(selected: selected))
            .i18nLabel("sidebar." + symbol, title)
            .accessibilityValue(selected ? L("message.current_page") : "")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Keep DisclosureGroup's binding and semantic expansion state, while replacing
/// the platform's small triangle with one full-width native Button.
struct WalletDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 12)
                    Text(configuration.isExpanded ? L("disclosure.collapse") : L("disclosure.expand")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.veilAccent)
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(selected: configuration.isExpanded, filled: true))
                .accessibilityValue(configuration.isExpanded ? L("message.expanded") : L("message.collapsed"))
                .accessibilityHint(L("message.click_the_whole_row_or_press_space_to_toggle_details"))
                .interactionFrame("disclosure.header")
            if configuration.isExpanded {
                configuration.content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.veilBackground.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.veilBorder).allowsHitTesting(false))
    }
}
struct SectionTitle: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2.5).foregroundStyle(Color.veilAccent)
            Text(title).font(.system(size: 30, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
}
struct FieldLabel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content.textFieldStyle(.roundedBorder)
        }
    }
}
struct ErrorText: View {
    let text: String?
    var body: some View {
        if let text { Label(LS(text), systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
}

// Disambiguate the property wrapper from the macOS 27 SDK State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

func walletDate(_ value: Date, date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
    value.formatted(Date.FormatStyle(date: date, time: time).locale(WalletLanguage.current.locale))
}
