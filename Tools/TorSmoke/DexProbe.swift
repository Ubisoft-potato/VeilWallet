import Foundation
import WalletCore

enum DexProbe {
    struct Row: Codable { let id: String; let venue: String; let chainID: UInt64; let status: String; let message: String }
    static let sender = "0x000000000000000000000000000000000000dEaD"
    @MainActor static func run(gate: NetworkGate) async throws {
        let args = CommandLine.arguments
        let filter = args.firstIndex(of: "--dex-ids").flatMap { $0 + 1 < args.count ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
        let reportPath = args.firstIndex(of: "--dex-report").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let defaults: Set<String> = ["uniswap-v2-1", "uniswap-v3-1", "uniswap-v3-8453", "uniswap-v4-1", "uniswap-v4-8453", "pancake-v2-56", "pancake-v3-56", "sushi-v2-1", "quick-v2-137", "quick-algebra-137", "aerodrome-8453", "velodrome-10", "aero-slipstream-8453", "velo-slipstream-10", "lfj-lb-43114", "curve-3pool-1", "curve-steth-1", "balancer-v3-1"]
        let selected = DexCatalog.all.filter { filter?.contains($0.id) ?? (args.contains("--dex-all") || defaults.contains($0.id)) }
        var rows: [Row] = []
        for batchStart in stride(from: 0, to: selected.count, by: 3) {
            let batch = Array(selected[batchStart..<min(batchStart + 3, selected.count)])
            let values = await withTaskGroup(of: Row.self) { group in
                for venue in batch { group.addTask { await check(venue, gate: gate) } }
                var result: [Row] = []; for await row in group { result.append(row) }; return result
            }
            rows += values
            for row in values { TorSmoke.output(row.status + ": " + row.venue + " / " + String(row.chainID) + " · " + row.message) }
            if let reportPath { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(rows).write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
        }
        if filter == nil || filter?.contains("tron") == true {
            do {
                guard var chain = NetworkCatalog.nativeChains.first(where: { $0.family == .tron }) else { throw WalletError.invalid("TRON catalog") }
                if let i = args.firstIndex(of: "--tron-rpc"), i + 1 < args.count { chain.rpcURL = args[i + 1] }
                let diagnostics = args.firstIndex(of: "--tron-diagnostics").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
                let client = TronContractClient(transport: TronProbeTransport(base: TorTransport(gate: gate), directory: diagnostics), chain: chain, isolation: UUID().uuidString)
                // Fixed public fixtures only; no private vault or signer.
                let token = try Token(chainID: chain.id, contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", symbol: "USDT", decimals: 6)
                for mode in TronDexMode.allCases {
                    var stage = "quote"
                    do {
                        // Caller and reviewed recipient must coincide. The public
                        // WTRX contract works for SUN; V2 additionally rejects pool
                        // tokens as receivers, so use its published deployer there.
                        let caller = mode == .smart ? TronDexClient.wrapped : "TU3rMHyWHzeEJBReWLzHko728hbz6MtfNg"
                        let quote = try await TronDexClient(client: client).quote(sender: caller, input: nil, output: token, amount: "1", mode: mode)
                        guard quote.minimumOut > 0 else { throw WalletError.invalid("TRON quote") }
                        stage = "swap simulation"
                        _ = try await client.read(quote.invocation, sender: caller)
                        rows.append(Row(id: "tron-" + mode.rawValue, venue: mode.name, chainID: chain.id, status: "PASS", message: "quote and full simulation over Tor with the same public caller and recipient; no signing/broadcast"))
                        TorSmoke.output("PASS: TRON / " + mode.name + " quote and full simulation over Tor")
                    } catch { rows.append(Row(id: "tron-" + mode.rawValue, venue: mode.name, chainID: chain.id, status: "UNAVAILABLE", message: stage + " · " + error.localizedDescription)); TorSmoke.output("UNAVAILABLE: TRON / " + mode.name + " · " + stage + " · " + error.localizedDescription) }
                }
            } catch { TorSmoke.output("UNAVAILABLE: TRON · " + error.localizedDescription) }
        }
        if let reportPath { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(rows).write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
    }
    static func check(_ venue: DexVenue, gate: NetworkGate) async -> Row {
        do {
            return try await withThrowingTaskGroup(of: Row.self) { group in
                group.addTask { await checkWithinDeadline(venue, gate: gate) }
                group.addTask { try await Task.sleep(for: .seconds(240)); throw WalletError.invalid("DEX 检查超时") }
                defer { group.cancelAll() }; return try await group.next()!
            }
        } catch { return Row(id: venue.id, venue: venue.name, chainID: venue.chainID, status: "UNAVAILABLE", message: error.localizedDescription) }
    }
    static func checkWithinDeadline(_ venue: DexVenue, gate: NetworkGate) async -> Row {
        var stage = "deployment"
        do {
            guard var chain = Chain.defaults.first(where: { $0.id == venue.chainID }) else { throw WalletError.invalid("Missing chain") }
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--evm-rpc"), i + 1 < args.count { chain.rpcURL = args[i + 1] }
            let rpc = RPCClient(transport: TorTransport(gate: gate), chain: chain, isolation: UUID().uuidString), dex = DexClient(rpc: rpc)
            try await dex.verifyVenue(venue.id)
            if let pair = try pair(venue) {
                stage = "quote"
                let quote = try await dex.quote(sender: sender, input: pair.input, output: pair.output, amount: pair.amount, venueID: venue.id, fee: pair.fee, poolID: venue.id == "balancer-v3-1" ? "0xbda917a67c7d9ae67da92c4ea87e10e5d6c11b54" : nil)
                guard quote.minimumOut > 0 else { throw WalletError.invalid("Empty quote") }
                if pair.input == nil, try await rpc.balance(address: sender) >= quote.invocation.nativeValue {
                    stage = "swap simulation"
                    _ = try await rpc.readContract(quote.invocation, sender: sender)
                    return Row(id: venue.id, venue: venue.name, chainID: venue.chainID, status: "PASS", message: "fixed deployment, quote and full swap simulation over Tor; no signing/broadcast")
                }
                return Row(id: venue.id, venue: venue.name, chainID: venue.chainID, status: "QUOTE", message: "fixed deployment and onchain quote; swap simulation not exercised")
            }
            return Row(id: venue.id, venue: venue.name, chainID: venue.chainID, status: "DEPLOYMENT", message: "deployment verified; pool-specific quote not exercised")
        } catch { return Row(id: venue.id, venue: venue.name, chainID: venue.chainID, status: "UNAVAILABLE", message: stage + " · " + error.localizedDescription) }
    }
    static func pair(_ venue: DexVenue) throws -> (input: Token?, output: Token, amount: String, fee: UInt32)? {
        let address: String, decimals: Int
        switch venue.chainID {
        case 1: address = venue.protocol == .curveETH ? "0xae7ab96520de3a18e5e111b5eaab095312d7fe84" : "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"; decimals = venue.protocol == .curveETH ? 18 : 6
        case 56: address = "0x55d398326f99059ff775485246999027b3197955"; decimals = 18
        case 8453: address = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"; decimals = 6
        case 10: address = "0x0b2c639c533813f4aa9d7837caf62653d097ff85"; decimals = 6
        case 137: address = "0x2791bca1f2de4661ed88a30c99a7a9449aa84174"; decimals = 6
        case 43114: address = "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e"; decimals = 6
        case 42161: address = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"; decimals = 6
        default:
            guard let preset = TokenCatalog.all.first(where: { $0.chainID == venue.chainID && ["USDC", "USDT"].contains($0.symbol) }) else { return nil }
            address = preset.token.contract; decimals = preset.token.decimals
        }
        if venue.protocol == .balancerV3 {
            guard venue.chainID == 1 else { return nil }
            return (nil, try Token(chainID: 1, contract: "0xec53bf9167f50cdeb3ae105f56099aaab9061f83", symbol: "TEST", decimals: 18), "0.001", 3000)
        }
        if venue.protocol == .curve {
            let input = try Token(chainID: venue.chainID, contract: address, symbol: "TEST", decimals: 6)
            let output = try Token(chainID: venue.chainID, contract: "0xdac17f958d2ee523a2206206994597c13d831ec7", symbol: "TEST", decimals: 6)
            return (input, output, "1", 3000)
        }
        return (nil, try Token(chainID: venue.chainID, contract: address, symbol: "TEST", decimals: decimals), "0.001", venue.protocol == .uniswapV4 ? 3000 : (venue.usesFee ? 0 : 3000))
    }
}

// Developer-only, explicitly enabled diagnostics for the public fixtures above.
// This transport is never used by the app, a vault, a signer or a broadcast.
private struct TronProbeTransport: PrivateRequesting {
    let base: TorTransport
    let directory: URL?
    func execute(_ request: PrivateRequest) async throws -> Data {
        let data = try await base.execute(request)
        if request.url.path == "/wallet/triggerconstantcontract", let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let body = try request.body.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
            let selector = String((body?["data"]?.string ?? "").prefix(8))
            try data.write(to: directory.appendingPathComponent(selector + "-" + UUID().uuidString + ".json"), options: .atomic)
        }
        return data
    }
}
