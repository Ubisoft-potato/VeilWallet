import SwiftUI

extension View {
    @ViewBuilder func i18nLabel(_ identifier: String, _ value: String) -> some View {
        #if DEBUG
        preference(key: I18nLabels.self, value: [identifier: value])
        #else
        self
        #endif
    }
    @ViewBuilder func interactionFrame(_ identifier: String) -> some View {
        #if DEBUG
        background(GeometryReader { proxy in Color.clear.preference(key: InteractionFrames.self, value: [identifier: proxy.frame(in: .named("interaction-check"))]) }.allowsHitTesting(false))
        #else
        self
        #endif
    }
    @ViewBuilder func observeHoverProbe(_ action: @escaping (Bool) -> Void) -> some View {
        #if DEBUG
        modifier(HoverProbeObserver(action: action))
        #else
        self
        #endif
    }
}
#if DEBUG
import AppKit
import Combine
import WalletCore

private struct I18nLabels: PreferenceKey {
    static var defaultValue: [String: String] = [:]
    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

private struct HoverProbeKey: EnvironmentKey { static let defaultValue: PassthroughSubject<Bool, Never>? = nil }
private extension EnvironmentValues {
    var hoverProbe: PassthroughSubject<Bool, Never>? {
        get { self[HoverProbeKey.self] }
        set { self[HoverProbeKey.self] = newValue }
    }
}
private struct HoverProbeObserver: ViewModifier {
    @Environment(\.hoverProbe) private var probe
    let action: (Bool) -> Void
    func body(content: Content) -> some View {
        content.onReceive(probe?.eraseToAnyPublisher() ?? Empty<Bool, Never>(completeImmediately: false).eraseToAnyPublisher(), perform: action)
    }
}

private struct InteractionFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

// Native click checks and injected hover-phase rendering checks against our own
// hierarchy. No system event injection, vault access or network connection.
@MainActor enum UIInteractionChecks {
    private final class MnemonicFixture: ObservableObject {
        @Published var draft = MnemonicImportDraft()
        @Published var disabled = false
    }
    private struct MnemonicControls: View {
        @ObservedObject var state: MnemonicFixture
        var body: some View {
            VStack {
                ScrollView { MnemonicInputGrid(draft: $state.draft).disabled(state.disabled) }.frame(height: 340)
                TextField(L("message.leave_blank_for_no_passphrase"), text: .constant(""))
            }.padding(30).buttonStyle(SecondaryButton())
        }
    }
    static func runMnemonic(to destination: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        WalletLocalization.useInMemoryLanguagePreferencesForVerification(.english)
        let state = MnemonicFixture(), geometry = Geometry()
        let (window, host) = makeHost(MnemonicControls(state: state), size: NSSize(width: 580, height: 760), geometry: geometry)
        defer { window.orderOut(nil) }
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        func word(_ index: Int) throws -> NSTextField {
            guard let field = fields(host).first(where: { $0.identifier?.rawValue == "mnemonic.word.\(index)" }) else {
                throw WalletError.invalid("mnemonic.nativeFieldMissing")
            }
            return field
        }
        func editor(_ index: Int) throws -> NSTextView {
            let field = try word(index)
            if field.currentEditor() == nil { try click(try frame("mnemonic.cell.\(index)", in: geometry), fraction: 0.92, host: host) }
            guard let editor = field.currentEditor() as? NSTextView else {
                let kind = field.currentEditor().map { String(describing: type(of: $0)) } ?? "nil"
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                throw WalletError.invalid("mnemonic.nativeEditorMissing.\(index).\(kind).\(responder)")
            }
            return editor
        }
        let first = try word(0)
        try require(fields(host).filter { $0 is NSSecureTextField }.count == 12, "mnemonic.twelveSecureCells")
        try require(try frame("mnemonic.cell.0", in: geometry).height >= 44, "mnemonic.cellHitHeight")
        try click(try frame("mnemonic.cell.0", in: geometry), fraction: 0.92, host: host)
        try require(first.currentEditor() != nil, "mnemonic.cellWhitespaceFocusesInput")
        let input = try editor(0)
        input.insertText(Mnemonic.words[0].uppercased(), replacementRange: NSRange(location: NSNotFound, length: 0)); settle(host)
        try require(state.draft.words[0] == Mnemonic.words[0], "mnemonic.normalizedNativeTyping")
        try require(!input.isContinuousSpellCheckingEnabled && !input.isAutomaticSpellingCorrectionEnabled && !input.isAutomaticTextCompletionEnabled && !input.allowsUndo, "mnemonic.noSpellcheckOrUndo")
        input.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0)); settle(host)
        try require(try word(1).currentEditor() != nil, "mnemonic.spaceAdvances")
        let next = try editor(1)
        next.doCommand(by: NSSelectorFromString("deleteBackward:")); settle(host)
        try require(try word(0).currentEditor() != nil, "mnemonic.emptyBackspaceReturns")
        let tab = try editor(0)
        tab.doCommand(by: NSSelectorFromString("insertTab:")); settle(host)
        try require(try word(1).currentEditor() != nil, "mnemonic.tabAdvances")
        let backtab = try editor(1)
        backtab.doCommand(by: NSSelectorFromString("insertBacktab:")); settle(host)
        try require(try word(0).currentEditor() != nil, "mnemonic.shiftTabReturns")
        let newline = try editor(0)
        newline.doCommand(by: NSSelectorFromString("insertNewline:")); settle(host)
        try require(try word(1).currentEditor() != nil, "mnemonic.returnAdvances")
        let phrase = try Mnemonic.fromEntropy(Data(repeating: 0, count: 32))
        let paste = try editor(4)
        paste.insertText(phrase.uppercased().replacingOccurrences(of: " ", with: "\n"), replacementRange: NSRange(location: NSNotFound, length: 0)); settle(host)
        try require(state.draft.count == 24 && state.draft.isValid, "mnemonic.nativeCompletePhraseInsertion")
        try require(fields(host).filter { $0 is NSSecureTextField }.count == 24, "mnemonic.twentyFourSecureCells")
        let saved = state.draft
        for language in [WalletLanguage.simplifiedChinese, .english] {
            WalletLanguage.select(language); settle(host)
            try require(state.draft == saved, "mnemonic.languagePreservesWords")
            try require(try word(0).accessibilityLabel() == L("message.word_0", 1), "mnemonic.languageUpdatesCellLabels")
        }
        try click(try frame("mnemonic.reveal", in: geometry), host: host)
        try require(!(try word(0) is NSSecureTextField) && state.draft == saved, "mnemonic.revealPreservesWords")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil); settle(host)
        try require(try word(0) is NSSecureTextField, "mnemonic.remasksOnAppBlur")
        state.disabled = true; settle(host)
        try require(!(try word(0).isEnabled), "mnemonic.disabledDuringProcessing")
        state.disabled = false; settle(host)
        try click(try frame("mnemonic.clear", in: geometry), host: host)
        try require(state.draft.count == 24 && state.draft.filledCount == 0, "mnemonic.clearRemovesEveryWord")
        _ = try editor(4)
        for index in 4..<23 {
            guard let current = try word(index).currentEditor() as? NSTextView else { throw WalletError.invalid("mnemonic.navigationEditorMissing") }
            current.doCommand(by: NSSelectorFromString("insertTab:")); settle(host)
        }
        try require(try word(23).currentEditor() != nil && !word(23).visibleRect.isEmpty, "mnemonic.scrollsToLastWord")
        for index in stride(from: 23, through: 1, by: -1) {
            guard let current = try word(index).currentEditor() as? NSTextView else { throw WalletError.invalid("mnemonic.navigationEditorMissing") }
            current.doCommand(by: NSSelectorFromString("insertBacktab:")); settle(host)
        }
        try require(try word(0).currentEditor() != nil && !word(0).visibleRect.isEmpty, "mnemonic.scrollsBackToFirstWord")
        let report: [String: Any] = ["passed": true, "wordCounts": [12, 24], "nativeTextInsertion": true,
                                    "keyboardNavigation": true, "scrollsBetweenFirstAndLastWord": true, "secureByDefault": true, "remasksOnBlur": true,
                                    "liveLanguagePreservesDraft": true, "vaultOpened": false, "networkStarted": false,
                                    "clipboardRead": false, "fixtures": "BIP39 public zero-entropy vectors"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }
    private static let hoverIDs = ["hover.row", "hover.selected", "hover.secondary", "hover.primary", "hover.warning", "hover.icon", "disclosure.header"]
    private final class Fixture: ObservableObject {
        @Published var expanded = false
        @Published var value = ""
        @Published var count = 0
        @Published var disabled = false
        let hover = Dictionary(uniqueKeysWithValues: UIInteractionChecks.hoverIDs.map { ($0, PassthroughSubject<Bool, Never>()) })
    }
    private final class Geometry { var frames: [String: CGRect] = [:] }
    private final class LanguageProbe { var labels: [String: String] = [:] }
    private struct LanguageDraft: View {
        @ViewState private var draft = "1.2345"
        @ViewState private var identity = UUID()
        var body: some View {
            HStack {
                Text(AccountProfile.find("monero.ledger")!.name).i18nLabel("profile", AccountProfile.find("monero.ledger")!.name)
                TextField(L("message.local_field"), text: $draft)
                Button(L("message.inner_action")) { draft = "9.8765" }.interactionFrame("language.edit")
            }.padding(14).buttonStyle(SecondaryButton())
                .preference(key: I18nLabels.self, value: ["draft": draft, "identity": identity.uuidString,
                                                         "profile": AccountProfile.find("monero.ledger")!.name])
        }
    }
    static func runLanguage(to destination: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        WalletLocalization.useInMemoryLanguagePreferencesForVerification(.english)
        let model = AppModel(previewMode: true), geometry = Geometry(), probe = LanguageProbe()
        model.route = .settings
        // Warm the static catalog before changing language to catch frozen profile labels.
        _ = AccountProfile.all
        let root = VStack(spacing: 0) { RootView().environmentObject(model); LanguageDraft().frame(height: 80) }
        let (window, host) = makeHost(root, size: NSSize(width: 1240, height: 1000), geometry: geometry, languageProbe: probe)
        defer { window.orderOut(nil) }
        try require(probe.labels["sidebar.square.stack.3d.up"] == "Assets", "i18n.initialEnglish")
        try require(probe.labels["draft"] == "1.2345", "i18n.initialDraft")
        try click(try frame("language.edit", in: geometry), host: host)
        let identity = probe.labels["identity"]
        try require(probe.labels["draft"] == "9.8765", "i18n.editedDraft")
        for language in [WalletLanguage.simplifiedChinese, .english] {
            try click(try frame("language.option." + language.rawValue, in: geometry), host: host)
            try require(WalletLanguage.current == language, "i18n.nativeLanguageSelection")
            try require(probe.labels["sidebar.square.stack.3d.up"] == WalletLocalization.text("navigation.assets", language: language), "i18n.sidebarUpdatedImmediately")
            try require(probe.labels["profile"] == WalletLocalization.text("message.monero_ledger_bip39_derivation", language: language), "i18n.cachedProfileUpdatedImmediately")
            try require(probe.labels["draft"] == "9.8765" && probe.labels["identity"] == identity, "i18n.formStatePreserved")
            try require(model.route == .settings && model.unlocked && model.sheet == nil, "i18n.sessionPreserved")
        }
        let report: [String: Any] = ["version": "0.10.1", "passed": true, "nativePointerEvents": true,
                                    "directions": ["en -> zh-Hans", "zh-Hans -> en"], "restartRequired": false,
                                    "sidebarUpdated": true, "warmedProfileCatalogUpdated": true, "draftAndViewIdentityPreserved": true,
                                    "vaultOpened": false, "networkStarted": false, "userPreferencesModified": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }
    private struct Controls: View {
        @ObservedObject var state: Fixture
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup(isExpanded: $state.expanded) {
                    TextField(L("message.local_field"), text: $state.value).interactionFrame("field")
                    Button(L("message.inner_action")) { state.count += 1 }.interactionFrame("inner")
                } label: { Text(L("message.advanced_settings_check")) }
                .disabled(state.disabled)
                IconButton(symbol: "doc.on.doc", title: L("message.test_copy_button")) { state.count += 1 }.interactionFrame("icon")
                ActionFlow { ForEach(0..<6) { index in Button(L("message.action_button_0", index + 1)) { state.count += 1 }.interactionFrame("flow.\(index)") } }
                Spacer()
            }.padding(24).buttonStyle(SecondaryButton()).disclosureGroupStyle(WalletDisclosureStyle())
        }
    }
    private struct HoverControls: View {
        @ObservedObject var state: Fixture
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                SidebarRow(title: L("message.hover_row_0", state.count), symbol: "square.grid.2x2", selected: false) {}.interactionFrame("hover.row").environment(\.hoverProbe, state.hover["hover.row"])
                SidebarRow(title: L("message.selected_row"), symbol: "checkmark.circle", selected: true) {}.interactionFrame("hover.selected").environment(\.hoverProbe, state.hover["hover.selected"])
                Button {} label: { Text(L("message.secondary_button_0", state.count)).frame(maxWidth: .infinity) }.interactionFrame("hover.secondary").environment(\.hoverProbe, state.hover["hover.secondary"])
                Button {} label: { Text(L("message.primary_button")).frame(maxWidth: .infinity) }.buttonStyle(PrimaryButton()).interactionFrame("hover.primary").environment(\.hoverProbe, state.hover["hover.primary"])
                Button {} label: { Text(L("message.action_requiring_caution")).frame(maxWidth: .infinity) }.buttonStyle(PrimaryButton(bodyColor: .orange)).interactionFrame("hover.warning").environment(\.hoverProbe, state.hover["hover.warning"])
                IconButton(symbol: "doc.on.doc", title: L("message.icon_button")) {}.interactionFrame("hover.icon").environment(\.hoverProbe, state.hover["hover.icon"])
                DisclosureGroup(L("message.details_heading")) { Text(L("message.details")) }.environment(\.hoverProbe, state.hover["disclosure.header"])
                Spacer()
            }.padding(24).buttonStyle(SecondaryButton()).disclosureGroupStyle(WalletDisclosureStyle()).disabled(state.disabled)
        }
    }
    static func runHover(to destination: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = Fixture(), geometry = Geometry()
        let (window, host) = makeHost(HoverControls(state: state), size: NSSize(width: 420, height: 580), geometry: geometry)
        defer { window.orderOut(nil) }
        var results: [[String: Any]] = [], passed = false
        defer {
            let report: [String: Any] = ["version": "0.10.1", "passed": passed, "nativePointerEvents": false, "phaseInjection": true, "phaseDelivery": "DEBUG-only enter/exit signals drive the same persistent view state as onContinuousHover; this does not verify OS pointer tracking", "networkStarted": false, "vaultOpened": false, "results": results]
            state.hover.values.forEach { $0.send(true) }
            wait(0.3, host: host)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: destination.deletingLastPathComponent().appendingPathComponent("hover-phase-held.png")) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: destination, options: .atomic) }
        }
        for id in hoverIDs {
            let probe = state.hover[id]!
            probe.send(false)
            wait(0.35, host: host)
            let rect = try frame(id, in: geometry)
            let point = NSPoint(x: rect.minX + (id == "hover.icon" ? 5 : rect.width * 0.7), y: rect.midY)
            let idle = try pixel(point, host: host)
            probe.send(true)
            wait(0.35, host: host)
            let held = try pixel(point, host: host)
            results.append(["id": id, "idle": idle, "held": held])
            try require(distance(idle, held) > 0.012, L("message.hover_highlight_is_visible") + id)
            state.count += 1; wait(0.4, host: host)
            let refreshed = try pixel(point, host: host)
            wait(0.8, host: host)
            let sustained = try pixel(point, host: host)
            try require(distance(held, refreshed) < 0.015 && distance(held, sustained) < 0.015, L("message.highlight_survives_holding_and_parent_refresh") + id)
            let coloredPrimary = ["hover.primary", "hover.warning"].contains(id)
            if !coloredPrimary { try require(sustained.max()! < 0.4, L("message.hover_background_stays_dark") + id) }
            probe.send(false)
            wait(0.4, host: host)
            let exited = try pixel(point, host: host)
            try require(distance(idle, exited) < 0.015, L("message.pointer_exit_restores_idle") + id)
            results[results.count - 1]["refreshed"] = refreshed
            results[results.count - 1]["sustained"] = sustained
            results[results.count - 1]["exited"] = exited
            state.disabled = true; wait(0.1, host: host)
            let disabledIdle = try pixel(point, host: host)
            probe.send(true); wait(0.3, host: host)
            let disabledHeld = try pixel(point, host: host)
            try require(distance(disabledIdle, disabledHeld) < 0.008, L("message.disabled_hover_stays_inactive") + id)
            probe.send(false); state.disabled = false; wait(0.3, host: host)
            for inside in [true, false, true, false, true] {
                probe.send(inside); wait(0.035, host: host)
                if !coloredPrimary { try require(try pixel(point, host: host).max()! < 0.4, L("message.rapid_entry_and_exit_do_not_flash_white") + id) }
            }
            wait(0.35, host: host)
            try require(distance(held, try pixel(point, host: host)) < 0.015, L("message.highlight_recovers_after_rapid_reentry") + id)
            probe.send(false); wait(0.3, host: host)
            results[results.count - 1]["disabledStable"] = true
            results[results.count - 1]["rapidReentryStable"] = true
        }
        passed = true
    }
    private static func wait(_ seconds: TimeInterval, host: NSView) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)); host.layoutSubtreeIfNeeded() }
    private static func pixel(_ point: CGPoint, host: NSView) throws -> [Double] {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw WalletError.invalid(L("message.ui_check_could_not_sample_the_rendered_view")) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / host.bounds.width), y = Int(point.y * CGFloat(bitmap.pixelsHigh) / host.bounds.height)
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw WalletError.invalid(L("message.ui_check_returned_an_invalid_color")) }
        return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }
    private static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double { zip(lhs, rhs).map { abs($0.0 - $0.1) }.max() ?? 0 }
    static func run(to destination: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks: [String] = []
        let model = AppModel(previewMode: true), navigation = Geometry()
        let (window, host) = makeHost(RootView().environmentObject(model), size: NSSize(width: 1080, height: 740), geometry: navigation)
        defer { window.orderOut(nil) }
        for route in Route.allCases {
            let rect = try frame("navigation." + route.id, in: navigation)
            try require(rect.height >= 48 && rect.width >= 200, L("message.full_sidebar_hit_area_dimensions"))
            try click(rect, fraction: 0.82, host: host)
            try require(model.route == route, L("message.sidebar_whitespace_navigation") + route.rawValue)
            checks.append("sidebar whitespace click: " + route.title)
        }
        model.busy = true; settle(host)
        try click(try frame("navigation." + Route.assets.id, in: navigation), fraction: 0.82, host: host)
        try require(model.route == .assets, L("message.navigation_remains_usable_during_background_work"))
        model.busy = false; checks.append("sidebar remains usable during background work")
        let state = Fixture(), geometry = Geometry()
        let (controlsWindow, controlsHost) = makeHost(Controls(state: state), size: NSSize(width: 360, height: 600), geometry: geometry)
        defer { controlsWindow.orderOut(nil) }
        func header() throws -> CGRect { try frame("disclosure.header", in: geometry) }
        let rect = try header()
        try require(rect.width >= 312 && rect.height >= 52, L("message.full_disclosure_heading_dimensions"))
        try click(rect, fraction: 0.65, host: controlsHost)
        try require(state.expanded, L("message.heading_whitespace_expands_content"))
        try click(try frame("field", in: geometry), host: controlsHost)
        try require(state.expanded, L("message.clicking_the_field_does_not_collapse_content"))
        state.value = "local form input"; settle(controlsHost)
        try click(try frame("inner", in: geometry), host: controlsHost)
        try require(state.count == 1 && state.expanded, L("message.the_inner_button_fires_once_without_collapsing"))
        try click(try header(), fraction: 0.65, host: controlsHost)
        try require(!state.expanded, L("message.heading_whitespace_collapses_content"))
        try click(try header(), fraction: 0.65, host: controlsHost)
        try require(state.expanded && state.value == "local form input", L("message.reopening_preserves_field_state"))
        checks.append("disclosure whitespace: expand, input focus, child action, collapse, reopen, preserved field state")
        let icon = try frame("icon", in: geometry)
        try require(icon.width >= 36 && icon.height >= 36, L("message.icon_button_dimensions"))
        try click(icon, host: controlsHost); try require(state.count == 2, L("message.icon_action_fires_once"))
        checks.append("icon: 36 x 36 minimum, single activation")
        state.disabled = true; settle(controlsHost)
        try click(try header(), fraction: 0.65, host: controlsHost)
        try require(state.expanded, L("message.disabled_disclosure_does_not_activate"))
        checks.append("disabled disclosure does not activate")
        let frames = try (0..<6).map { try frame("flow.\($0)", in: geometry) }
        try require(Set(frames.map { Int($0.minY.rounded()) }).count > 1, L("message.actions_wrap_in_a_narrow_window"))
        for rect in frames {
            try require(rect.minX >= 24 && rect.maxX <= 336 && rect.height >= 40, L("message.wrapped_buttons_preserve_dimensions_without_overflowing"))
            try click(rect, host: controlsHost)
        }
        try require(state.count == 8, L("message.all_six_wrapped_buttons_respond_independently_once"))
        checks.append("action flow: six independent clicks, wraps at 360 pt viewport, no overflow")
        state.disabled = false; settle(controlsHost)
        if let bitmap = controlsHost.bitmapImageRepForCachingDisplay(in: controlsHost.bounds) {
            controlsHost.cacheDisplay(in: controlsHost.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: destination.deletingLastPathComponent().appendingPathComponent("interaction-expanded.png"), options: .atomic) }
        }
        let report: [String: Any] = ["version": "0.10.1", "networkStarted": false, "vaultOpened": false, "nativePointerEvents": true, "checks": checks, "passed": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }
    private static func makeHost<V: View>(_ root: V, size: NSSize, geometry: Geometry, languageProbe: LanguageProbe? = nil) -> (NSWindow, NSHostingView<some View>) {
        let view = NSHostingView(rootView: root.preferredColorScheme(.dark).frame(width: size.width, height: size.height).background(Color.veilBackground).coordinateSpace(name: "interaction-check").onPreferenceChange(InteractionFrames.self) { geometry.frames = $0 }.onPreferenceChange(I18nLabels.self) { languageProbe?.labels = $0 })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; window.setFrameOrigin(NSPoint(x: -10000, y: 0)); window.orderFront(nil); settle(view)
        return (window, view)
    }
    private static func click(_ rect: CGRect, fraction: CGFloat = 0.5, host: NSView) throws {
        guard let window = host.window else { throw WalletError.invalid(L("message.ui_check_window_missing")) }
        let local = NSPoint(x: rect.minX + rect.width * fraction, y: host.isFlipped ? rect.midY : host.bounds.height - rect.midY)
        let point = host.convert(local, to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw WalletError.invalid(L("message.ui_check_could_not_construct_pointer_events")) }
        host.mouseDown(with: down); host.mouseUp(with: up); settle(host)
    }
    private static func frame(_ id: String, in geometry: Geometry) throws -> CGRect {
        guard let rect = geometry.frames[id], !rect.isEmpty else { throw WalletError.invalid(L("message.ui_check_layout_not_found") + id) }; return rect
    }
    private static func settle(_ view: NSView) { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.18)); view.layoutSubtreeIfNeeded() }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { guard try condition() else { throw WalletError.invalid(L("message.ui_check_failed") + message) } }
}
#endif
