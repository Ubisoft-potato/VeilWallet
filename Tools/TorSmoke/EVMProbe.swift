import Foundation
import WalletCore

struct EVMProbeResult: Codable, Sendable {
    let chainID: UInt64
    let name: String
    let rpcURL: String
    let feeModel: String
    var status = "unavailable"
    var balanceRead = false
    var feeQuote = false
    var gasEstimate = false
    var additionalFeeEstimate = false
    var message: String?
}
struct EVMProbeReport: Codable {
    let checkedAt: Date
    var usesPublicAddress = true
    var broadcastsTransactions = false
    let results: [EVMProbeResult]
}
@MainActor enum EVMProbe {
    static func run(gate: NetworkGate) async throws {
        let args = CommandLine.arguments
        var chains = Chain.defaults.filter { $0.isEVM && !$0.isTestnet && (args.contains("--evm-all") || $0.isMainstreamEVM) }
        if let index = args.firstIndex(of: "--evm-ids"), args.count > index + 1 {
            let ids = Set(args[index + 1].split(separator: ",").compactMap { UInt64($0) })
            chains = Chain.defaults.filter { $0.isEVM && ids.contains($0.id) }
        }
        for index in args.indices where args[index] == "--evm-rpc" && index + 1 < args.count {
            let pair = args[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let id = UInt64(pair[0]), let url = URL(string: pair[1]), url.scheme == "https", url.user == nil, url.password == nil else { throw WalletError.invalid("Invalid probe RPC override") }
            if let item = chains.firstIndex(where: { $0.id == id }) { chains[item].rpcURL = pair[1] }
        }
        var results: [EVMProbeResult] = []
        await withTaskGroup(of: EVMProbeResult.self) { group in
            var next = 0
            for _ in 0..<min(3, chains.count) {
                let chain = chains[next]; next += 1
                group.addTask { await inspect(chain, gate: gate) }
            }
            while let result = await group.next() {
                results.append(result)
                TorSmoke.output(result.status.uppercased() + ": " + result.name + " (" + String(result.chainID) + ") · " + (result.message ?? result.feeModel))
                if next < chains.count {
                    let chain = chains[next]; next += 1
                    group.addTask { await inspect(chain, gate: gate) }
                }
            }
        }
        results.sort { $0.chainID < $1.chainID }
        if let index = args.firstIndex(of: "--evm-report"), args.count > index + 1 {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(EVMProbeReport(checkedAt: Date(), results: results)).write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
        TorSmoke.output("EVM: " + String(results.filter { $0.status == "ready" }.count) + " ready / " + String(results.count) + " checked; no signatures or broadcasts")
    }
    nonisolated static func inspect(_ chain: Chain, gate: NetworkGate) async -> EVMProbeResult {
        var result = EVMProbeResult(chainID: chain.id, name: chain.name, rpcURL: chain.rpcURL, feeModel: chain.evmFeeModel.rawValue)
        do {
            return try await withThrowingTaskGroup(of: EVMProbeResult.self) { group in
                group.addTask {
                    var item = result
                    var stage = "chain ID"
                    do {
                    let client = RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: "evm-probe:" + String(chain.id) + ":" + UUID().uuidString)
                    try await client.verifyChain()
                    // A public burn address; never read a user wallet or transmit an address set.
                    let address = "0x000000000000000000000000000000000000dEaD"
                    stage = "balance"
                    _ = try await client.balance(address: address); item.balanceRead = true
                    stage = "fee quote"
                    let quote = try await client.feeQuote(); item.feeQuote = true
                    if !chain.canTransfer { item.status = "readOnly"; item.message = chain.feeNotice; return item }
                    do {
                        stage = "estimate gas"
                        let response = try await client.call("eth_estimateGas", params: [.object(["from": .string(address), "to": .string(address), "value": .string("0x0")])])
                        guard let hex = response.string else { throw WalletError.invalid("Gas 估算缺少整数结果") }
                        let gas = try Ethereum.decodeQuantity(hex)
                        let transaction = try EVMTransaction(chainID: chain.id, nonce: 0, maxPriorityFee: quote.maxPriorityFee, maxFee: quote.maxFee, gasLimit: (gas * 120 + 99) / 100, to: address, value: 0, mode: quote.mode)
                        item.gasEstimate = true
                        stage = "additional fee"
                        _ = try await client.additionalFees(for: transaction)
                        item.additionalFeeEstimate = chain.evmFeeModel != .executionOnly
                        item.status = item.additionalFeeEstimate ? "ready" : "partial"
                        item.message = chain.feeNotice
                    } catch { item.status = "partial"; item.message = stage + ": " + error.localizedDescription }
                    } catch { item.message = stage + ": " + error.localizedDescription }
                    return item
                }
                group.addTask { try await Task.sleep(for: .seconds(45)); throw WalletError.invalid("Tor 节点检查超时") }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw WalletError.invalid("没有节点检查结果") }; return first
            }
        } catch { result.message = error.localizedDescription; return result }
    }
}
