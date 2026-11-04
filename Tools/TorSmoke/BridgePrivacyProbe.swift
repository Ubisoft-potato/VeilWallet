import Foundation
import WalletCore

enum BridgePrivacyProbe {
    @MainActor static func run(gate: NetworkGate) async throws {
        let client = BridgeClient(transport: TorTransport(gate: gate), chains: Chain.defaults, isolation: UUID().uuidString)
        var reports: [[String: String]] = [], failures = 0
        if CommandLine.arguments.contains("--bridge-probe") {
            for source in BridgeCatalog.deployments {
                guard let destination = BridgeCatalog.destinations(for: source).first else { continue }
                do {
                    let sender = source.networkID == TronAddress.chainID ? "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR" : "0x000000000000000000000000000000000000dEaD"
                    let recipient = destination.networkID == TronAddress.chainID ? "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR" : "0x000000000000000000000000000000000000dEaD"
                    let quote = try await client.quote(sourceID: source.id, destinationID: destination.id, sender: sender, recipient: recipient, amount: "10")
                    reports.append(["route": source.id + " → " + destination.id, "result": "quote-pass", "minimumDestination": String(quote.minimumDestination), "nativeFee": String(quote.nativeFee)])
                    TorSmoke.output("PASS: " + source.id + " live on-chain quote over Tor")
                } catch {
                    failures += 1; reports.append(["route": source.id, "result": "unavailable", "reason": error.localizedDescription])
                    TorSmoke.output("UNAVAILABLE: " + source.id + " · " + error.localizedDescription)
                }
            }
        }
        if CommandLine.arguments.contains("--privacy-probe") {
            guard let index = CommandLine.arguments.firstIndex(of: "--proof-runtime"), CommandLine.arguments.indices.contains(index + 1) else { throw WalletError.invalid("Specify --proof-runtime directory") }
            let runtime = PrivacyProofRuntime(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            for id: UInt64 in [1, 56] {
                do {
                    let chain = Chain.defaults.first { $0.id == id }!, pool = PrivacyPoolCatalog.on(id)[0]
                    let privacy = PrivacyPoolClient(rpc: RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: UUID().uuidString))
                    try await privacy.verifyPublicProver(pool: pool, runtime: runtime)
                    for other in PrivacyPoolCatalog.on(id).dropFirst() { _ = try await privacy.verify(other) }
                    reports.append(["protocol": "tornado-classic-" + String(id), "result": "all-pool-getters-and-public-proof-pass"])
                    TorSmoke.output("PASS: Classic fixed pools and public Groth16 proof accepted on chain " + String(id))
                } catch {
                    failures += 1; reports.append(["protocol": "tornado-classic-" + String(id), "result": "unavailable", "reason": error.localizedDescription])
                    TorSmoke.output("UNAVAILABLE: privacy verifier " + String(id) + " · " + error.localizedDescription)
                }
            }
            await runtime.stop()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--bridge-privacy-report"), CommandLine.arguments.indices.contains(index + 1) {
            let report: [String: Any] = ["generatedAt": ISO8601DateFormatter().string(from: Date()), "scope": "Read-only public fixtures; no signing, funded simulation or broadcast", "checks": reports]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        if failures > 0 { throw WalletError.invalid("\(failures) bridge/privacy live checks unavailable; see report") }
    }
}
