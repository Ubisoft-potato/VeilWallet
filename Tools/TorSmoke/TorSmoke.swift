import Foundation
import WalletCore

@main struct TorSmoke {
    @MainActor static func main() async {
        do { try await run() }
        catch { output("FAIL: " + error.localizedDescription); exit(1) }
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count >= 2 else { throw WalletError.invalid("Usage: TorSmoke /absolute/path/to/TorRuntime.bundle [--networks | --litecoin | --evm | --evm-all] [--evm-ids IDs] [--evm-report path]") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veil-tor-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NetworkGate()
        let tor = TorController(gate: gate, bundle: URL(fileURLWithPath: CommandLine.arguments[1]), dataDirectory: directory)
        defer { tor.stop() }
        let bridges = (ProcessInfo.processInfo.environment["VEIL_TOR_SMOKE_BRIDGES"] ?? "").split(whereSeparator: \.isNewline).map(String.init)
        tor.start(bridges: bridges)
        var previous = ""
        for _ in 0..<240 {
            if previous != tor.state.label { output(tor.state.label); previous = tor.state.label }
            if tor.state == .ready { break }
            if case .failed(let message) = tor.state { throw WalletError.invalid(message) }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard gate.isReady else { throw WalletError.invalid("Tor did not bootstrap within 120 seconds; all requests remain blocked") }
        let request = try PrivateRequest(url: URL(string: "https://check.torproject.org/api/ip")!, isolation: UUID().uuidString)
        let response = try await TorTransport(gate: gate).execute(request)
        let json = try JSONDecoder().decode(JSONValue.self, from: response)
        guard json["IsTor"] == .bool(true) else { throw WalletError.invalid("Tor exit verification failed") }
        output("PASS: Tor exit verified (IP deliberately omitted)")
        try await RPCClient(transport: TorTransport(gate: gate), chain: Chain.defaults[0], isolation: UUID().uuidString).verifyChain()
        output("PASS: default EVM chain ID verified over Tor")
        if CommandLine.arguments.contains("--networks") || CommandLine.arguments.contains("--litecoin") {
            let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            let accounts = try MultichainCrypto.deriveAccounts(phrase: phrase)
            let litecoinOnly = CommandLine.arguments.contains("--litecoin")
            let native = NetworkCatalog.nativeChains.filter { ![.nostr, .starknet, .eos].contains($0.family) && $0.configured && (!litecoinOnly || $0.family == .litecoin) }
            for chain in native {
                let selected = accounts.filter { chain.profileKeys.contains($0.profileID) && $0.supportsPublicBalanceQuery }
                for account in litecoinOnly ? selected : Array(selected.prefix(1)) {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            _ = try await NativeBalanceClient(transport: TorTransport(gate: gate), chain: chain, isolation: UUID().uuidString).balance(account: account)
                        }
                        group.addTask { try await Task.sleep(for: .seconds(25)); throw WalletError.invalid("节点检查超时") }
                        defer { group.cancelAll() }; _ = try await group.next()
                    }
                    output("PASS: " + chain.name + (litecoinOnly ? " / " + account.profileID : "") + " balance over Tor")
                } catch {
                    if litecoinOnly { throw error }
                    output("UNAVAILABLE: " + chain.name + " · " + error.localizedDescription)
                }
                }
            }
        }
        if CommandLine.arguments.contains("--evm") || CommandLine.arguments.contains("--evm-all") || CommandLine.arguments.contains("--evm-ids") {
            try await EVMProbe.run(gate: gate)
        }
        if CommandLine.arguments.contains("--contracts") { try await ContractProbe.run(gate: gate) }
        if CommandLine.arguments.contains("--asset-probe") { try await PortfolioProbe.run(gate: gate) }
        if CommandLine.arguments.contains("--market-probe") { try await MarketPriceProbe.run(gate: gate) }
        if CommandLine.arguments.contains("--transactions") { try await TransactionProbe.run(gate: gate) }
        if CommandLine.arguments.contains("--inspect-bsc-swap") { try await SwapInspectionProbe.run(gate: gate) }
        if CommandLine.arguments.contains("--bridge-probe") || CommandLine.arguments.contains("--privacy-probe") { try await BridgePrivacyProbe.run(gate: gate) }
        if CommandLine.arguments.contains("--dex") || CommandLine.arguments.contains("--dex-all") || CommandLine.arguments.contains("--dex-ids") { try await DexProbe.run(gate: gate) }
        tor.stop()
        do {
            _ = try await TorTransport(gate: gate).execute(request)
            throw WalletError.invalid("Kill switch failed")
        } catch WalletError.networkBlocked { output("PASS: stopped Tor blocks requests") }
    }
    static func output(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
}
