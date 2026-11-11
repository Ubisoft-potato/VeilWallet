import SwiftUI
import WalletCore

@main
struct VeilWalletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--verify-asset-groups"), CommandLine.arguments.count > index + 1 {
            do { try UIInteractionChecks.runAssetGroups(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-mnemonic"), CommandLine.arguments.count > index + 1 {
            do { try UIInteractionChecks.runMnemonic(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-i18n"), CommandLine.arguments.count > index + 1 {
            do { try UIInteractionChecks.runLanguage(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-hover"), CommandLine.arguments.count > index + 1 {
            do { try UIInteractionChecks.runHover(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-ui"), CommandLine.arguments.count > index + 1 {
            do { try UIInteractionChecks.run(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { FileHandle.standardError.write(Data("Preview rendering failed\n".utf8)); exit(1) }
            exit(0)
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 740)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L("wallet.lock")) { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.tor.stop(); model?.monero.stop(); model?.proofRuntime.stopImmediately() }
    func applicationDidBecomeActive(_ notification: Notification) { model?.checkAutoLock() }
}
