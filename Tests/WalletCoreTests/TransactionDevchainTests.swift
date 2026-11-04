import Foundation
import Testing
import BigInt
@testable import WalletCore

// Test-only transport: this exception never enters Sources or the shipped app.
// The target is an ephemeral literal-loopback chain created with public keys.
private actor DevchainTransport: PrivateRequesting {
    let port: Int
    private var dropSend = false
    init(port: Int) { self.port = port }
    func dropNextSendResponse() { dropSend = true }
    func execute(_ request: PrivateRequest) async throws -> Data {
        guard request.url.absoluteString == "https://evm-local.invalid", let body = request.body else { throw WalletError.invalid("Test transport rejected a non-local fixture") }
        let input = try JSONDecoder().decode(JSONValue.self, from: body)
        let response = try await post(body)
        if dropSend, input["method"] == .string("eth_sendRawTransaction") { dropSend = false; throw WalletError.transport(28) }
        return response
    }
    private func post(_ data: Data) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]; config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!); request.httpMethod = "POST"; request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WalletError.invalid("Isolated chain HTTP error") }; return bytes
    }
    func control(_ method: String, params: [JSONValue] = []) async throws -> JSONValue {
        guard ["evm_mine", "evm_snapshot", "evm_revert", "anvil_setBalance", "anvil_setCode", "eth_getStorageAt"].contains(method) else { throw WalletError.invalid("Test control rejected method") }
        let id = UUID().uuidString, data = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .array(params)]))
        let result = try JSONDecoder().decode(JSONValue.self, from: await post(data))
        guard result["id"] == .string(id), result["error"] == nil, let value = result["result"] else { throw WalletError.invalid("Isolated chain control error") }; return value
    }
}
@Suite(.serialized) struct TransactionDevchainTests {
    @Test func actualEVMQueueSpeedUpCancelAndLostResponseNeverDuplicatePayment() async throws {
        let executable = ProcessInfo.processInfo.environment["VEIL_ANVIL"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".foundry/bin/anvil")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--host", "127.0.0.1", "--port", "0", "--chain-id", "1337", "--no-mining", "--hardfork", "shanghai", "--accounts", "1", "--mnemonic", "test test test test test test test test test test test junk"]
        process.environment = ["PATH": "/usr/bin:/bin"]; process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let startupTimeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: startupTimeout)
        defer { startupTimeout.cancel() }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    var line = Data(), count = 0
                    while let part = try output.fileHandleForReading.read(upToCount: 1), !part.isEmpty {
                        count += 1; guard count < 64 * 1024 else { throw WalletError.invalid("Test chain startup protocol") }
                        if part == Data([10]) {
                            let value = String(decoding: line, as: UTF8.self)
                            if let marker = value.range(of: "Listening on 127.0.0.1:"), let port = Int(value[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) {
                                continuation.resume(returning: port); return
                            }
                            line.removeAll(keepingCapacity: true)
                        } else { line += part }
                    }
                    throw WalletError.invalid("Isolated devchain unavailable")
                } catch { continuation.resume(throwing: error) }
            }
        }
        startupTimeout.cancel()
        guard (1...65535).contains(port) else { throw WalletError.invalid("Isolated devchain port invalid") }
        let transport = DevchainTransport(port: port)
        let chain = Chain(id: 1337, name: "Isolated test chain", symbol: "ETH", rpcURL: "https://evm-local.invalid")
        let rpc = RPCClient(transport: transport, chain: chain, isolation: "local-test")
        let key = Data(repeating: 1, count: 32), owner = try Ethereum.address(privateKey: key), recipient = "0x000000000000000000000000000000000000dEaD"
        _ = try await transport.control("anvil_setBalance", params: [.string(owner), .string(Ethereum.quantity(BigUInt(1000) * BigUInt(10).power(18)))])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("local.sealed"), testingKey: Data(repeating: 8, count: 32))
        func record(_ preview: TransactionPreview, group: UUID? = nil, action: TransactionAction = .original) async throws -> (Activity, TransactionArchive) {
            let raw = try preview.transaction.signed(privateKey: key)
            var item = Activity(walletID: UUID(), chainID: chain.id, hash: "0x" + raw.keccak256.hexString, to: preview.recipient, amount: preview.amount, symbol: preview.symbol)
            item.transaction = .evm(preview, groupID: group ?? item.id, action: action)
            item.transaction?.broadcastAttempts = 1; item.transaction?.observation = TransactionObservation(.broadcastUnknown)
            var archive = try TransactionArchive(activityID: item.id, walletID: item.walletID, preview: preview, raw: raw); archive.activity = item
            try await store.saveTransaction(archive); return (item, archive)
        }
        func mine() async throws { for _ in 0..<13 { _ = try await transport.control("evm_mine") } }
        // Queue a second nonce even when the provider's pending view lags.
        let first = try await rpc.prepare(sender: owner, recipient: recipient, amount: "0.1")
        let (original, archive) = try await record(first)
        _ = try await rpc.broadcast(Data(strictHex: archive.signedPayload))
        let queuedRPC = RPCClient(transport: transport, chain: chain, isolation: "local-test", noncePolicy: .init(activities: [original]))
        let next = try await queuedRPC.prepare(sender: owner, recipient: recipient, amount: "0.2")
        #expect(next.transaction.nonce == 1)
        // Replace the first transaction; only the accelerated hash is mined.
        let speed = try await rpc.prepareReplacement(archive: archive, record: original.transaction!, action: .speedUp)
        let (accelerated, acceleratedArchive) = try await record(speed, group: original.transaction!.groupID, action: .speedUp)
        _ = try await rpc.broadcast(Data(strictHex: acceleratedArchive.signedPayload)); try await mine()
        let acceleratedResult = try await rpc.observeGroup([original, accelerated])
        #expect(acceleratedResult[original.id]?.phase == .replaced)
        #expect(acceleratedResult[accelerated.id]?.phase == .confirmed)
        #expect(try await rpc.balance(address: recipient) == Ethereum.parseUnits("0.1"))
        // Cancel the next nonce; the recipient must never receive its amount.
        let payment = try await rpc.prepare(sender: owner, recipient: recipient, amount: "0.2")
        let (pending, pendingArchive) = try await record(payment)
        _ = try await rpc.broadcast(Data(strictHex: pendingArchive.signedPayload))
        let cancellation = try await rpc.prepareReplacement(archive: pendingArchive, record: pending.transaction!, action: .cancel)
        let (cancel, cancelArchive) = try await record(cancellation, group: pending.transaction!.groupID, action: .cancel)
        _ = try await rpc.broadcast(Data(strictHex: cancelArchive.signedPayload)); try await mine()
        let cancelled = try await rpc.observeGroup([pending, cancel])
        #expect(cancelled[pending.id]?.phase == .replaced); #expect(cancelled[cancel.id]?.phase == .cancelled)
        #expect(try await rpc.balance(address: recipient) == Ethereum.parseUnits("0.1"))
        // The node accepts a transaction but its response is lost. Recovered
        // archives keep the same signed bytes; retry cannot become a new nonce.
        let last = try await rpc.prepare(sender: owner, recipient: recipient, amount: "0.3")
        let (uncertain, uncertainArchive) = try await record(last)
        await transport.dropNextSendResponse()
        do { _ = try await rpc.broadcast(Data(strictHex: uncertainArchive.signedPayload)); Issue.record("Lost response was not simulated") } catch WalletError.transport(28) {}
        let recovered = try await store.recoverTransactions(into: [])
        #expect(recovered.contains { $0.id == uncertain.id && $0.phase == .broadcastUnknown })
        let replay = try await store.transaction(id: uncertain.id)
        #expect(replay.hash == uncertain.hash); #expect(replay.signedPayload == uncertainArchive.signedPayload)
        // Some clients report already-known / underpriced for the same bytes.
        do { _ = try await rpc.broadcast(Data(strictHex: replay.signedPayload)) } catch WalletError.rpcRejected {}
        try await mine()
        #expect(try await rpc.observe(activity: uncertain).phase == .confirmed)
        #expect(try await rpc.balance(address: recipient) == Ethereum.parseUnits("0.4"))
        #expect(try await rpc.nonceState(sender: owner).latest == 3)
        // A tiny public test contract increments slot 0. eth_call / estimation
        // leave no state; replacing a real contract transaction executes once.
        let contract = "0x0000000000000000000000000000000000001000"
        _ = try await transport.control("anvil_setCode", params: [.string(contract), .string("0x60005460010160005500")])
        let invocation = try ContractInvocation(contract: contract, signature: "increment()", arguments: [])
        let contractPreview = try await rpc.prepareContract(sender: owner, invocation: invocation)
        let (contractItem, contractArchive) = try await record(contractPreview)
        _ = try await rpc.broadcast(Data(strictHex: contractArchive.signedPayload))
        let contractSpeed = try await rpc.prepareReplacement(archive: contractArchive, record: contractItem.transaction!, action: .speedUp)
        let (contractReplacement, contractReplacementArchive) = try await record(contractSpeed, group: contractItem.transaction!.groupID, action: .speedUp)
        _ = try await rpc.broadcast(Data(strictHex: contractReplacementArchive.signedPayload)); try await mine()
        let contractResults = try await rpc.observeGroup([contractItem, contractReplacement])
        #expect(contractResults[contractItem.id]?.phase == .replaced)
        #expect(contractResults[contractReplacement.id]?.phase == .confirmed)
        let stored = try await transport.control("eth_getStorageAt", params: [.string(contract), .string("0x0"), .string("latest")])
        #expect(try Ethereum.decodeQuantity(stored.string!) == 1)
        #expect(try await rpc.nonceState(sender: owner).latest == 4)
    }
}
