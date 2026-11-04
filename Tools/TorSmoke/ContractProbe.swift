import Foundation
import WalletCore

enum ContractProbe {
    static func run(gate: NetworkGate) async throws {
        for id in DexClient.deployments.keys.sorted() {
            guard let chain = Chain.defaults.first(where: { $0.id == id }), let deployment = DexClient.deployments[id] else { continue }
            do {
                let client = RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: UUID().uuidString)
                let factory = try ContractABI.address(await client.readContract(ContractInvocation(contract: deployment.router, signature: "factory()", arguments: [])))
                guard factory.lowercased() == deployment.factory else { throw WalletError.invalid("Router factory mismatch") }
                _ = try ContractABI.address(await client.readContract(ContractInvocation(contract: deployment.router, signature: "WETH()", arguments: [])))
                TorSmoke.output("PASS: " + chain.name + " Router02 code / factory / wrapped asset over Tor")
            } catch { TorSmoke.output("UNAVAILABLE: " + chain.name + " Router02 · " + error.localizedDescription) }
        }
    }
}
