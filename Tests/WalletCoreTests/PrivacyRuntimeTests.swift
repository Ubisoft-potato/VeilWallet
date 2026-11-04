import Testing
import Foundation
@testable import WalletCore

@Suite(.serialized) struct PrivacyRuntimeTests {
    private var runtimeDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/PrivacyRuntime") }
    @Test func fullOfflineProofAndEncryptedNotesSurvivePasswordRotationAndRemoval() async throws {
        guard FileManager.default.fileExists(atPath: runtimeDirectory.appendingPathComponent("manifest.json").path) else { return }
        let runtime = PrivacyProofRuntime(directory: runtimeDirectory)
        let proof = try await runtime.publicFixtureProof()
        #expect(proof.publicSignals.count == 6); #expect(proof.publicSignals[2] == "57005")
        #expect(try Data(strictHex: proof.proof).count == 256)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vault.json"), vault = VaultStore(url: url), password = "public-test-password-only"
        try await vault.create(password: password)
        let wallet = try await vault.addPrivateKey(name: "Fixture", hex: String(repeating: "01", count: 32))
        let canonical = "tornado-eth-0.1-1-0x" + String(repeating: "00", count: 62)
        let note = try await vault.importPrivacyNote(canonical, password: password, runtime: runtime)
        #expect(note.commitment == proof.commitment)
        let duplicate = try await vault.importPrivacyNote(canonical, password: password, runtime: runtime)
        #expect(duplicate.id == note.id)
        do { _ = try await vault.privacyNote(id: note.id, password: "wrong"); Issue.record("Note export accepted wrong password") } catch {}
        let encrypted = try Data(contentsOf: url)
        #expect(!String(decoding: encrypted, as: UTF8.self).contains(canonical))
        try await vault.remove(walletID: wallet.id, password: password)
        try await vault.changePassword(current: password, replacement: "replacement-test-password")
        await vault.lock()
        do { _ = try await vault.privacyNotes(); Issue.record("Locked notes exposed") } catch {}
        _ = try await vault.unlock(password: "replacement-test-password")
        #expect(try await vault.privacyNote(id: note.id, password: "replacement-test-password") == canonical)
        let intent = PrivacyTransactionIntent(kind: .deposit, noteID: note.id, poolID: note.poolID, recipient: wallet.address, commitment: note.commitment, root: nil, nullifierHash: nil, fee: 0)
        try await vault.recordPrivacyTransaction(intent, hash: "0x" + String(repeating: "01", count: 32), password: "replacement-test-password")
        do { try await vault.authorizePrivacy(intent, password: "replacement-test-password"); Issue.record("Uncertain deposit permitted duplicate send") } catch {}
        let withdrawal = PrivacyTransactionIntent(kind: .withdraw, noteID: note.id, poolID: note.poolID, recipient: wallet.address, commitment: note.commitment, root: proof.root, nullifierHash: proof.nullifierHash, fee: 0)
        do { try await vault.authorizePrivacy(withdrawal, password: "replacement-test-password"); Issue.record("Withdrawal to original payer accepted") } catch {}
        let key = Data(repeating: 1, count: 32), originalHash = "0x" + String(repeating: "01", count: 32)
        let cancel = try EVMTransaction(chainID: 1, nonce: 0, maxPriorityFee: 1, maxFee: 10, gasLimit: 25_200, to: wallet.address, value: 0)
        let ref = EVMReplacementReference(activityID: UUID(), groupID: UUID(), hash: originalHash, original: cancel, action: .cancel, minimumMaxFee: 1, minimumPriorityFee: 1)
        let preview = TransactionPreview(transaction: cancel, sender: wallet.address, recipient: wallet.address, amount: "0", symbol: "ETH", preparedAt: Date(), token: nil, additionalFees: .zero, purpose: .transfer, replacement: ref)
        let raw = try cancel.signed(privateKey: key)
        var item = Activity(walletID: wallet.id, chainID: 1, hash: "0x" + raw.keccak256.hexString, to: wallet.address, amount: "0", symbol: "ETH")
        item.privacyNoteID = note.id; item.transaction = .evm(preview, groupID: ref.groupID, action: .cancel)
        var archive = try TransactionArchive(activityID: item.id, walletID: wallet.id, preview: preview, raw: raw); archive.activity = item
        try await vault.authorizeArchivedPrivacy(intent, archive: archive, password: "replacement-test-password")
        try await vault.authorizePrivacyRetry(intent, hash: item.hash, password: "replacement-test-password")
        #expect(try await vault.privacyNotes().first?.depositHash == originalHash)
        // Removing an unbroadcast replacement must retain the original note's
        // uncertain deposit reservation.
        try await vault.releaseUnbroadcastPrivacy(intent, archive: archive, password: "replacement-test-password")
        #expect(try await vault.privacyNotes().first?.depositHash == originalHash)
        do { try await vault.authorizePrivacyRetry(intent, hash: item.hash, password: "replacement-test-password"); Issue.record("Discarded note replacement remained authorized") } catch {}
        try await vault.authorizeArchivedPrivacy(intent, archive: archive, password: "replacement-test-password")
        item.transaction?.broadcastAttempts = 1; item.transaction?.observation = TransactionObservation(.cancelled); archive.activity = item
        let chain = try #require(Chain.defaults.first { $0.id == 1 })
        let rpc = RPCClient(transport: PrivacyCancelReceipt(item: item), chain: chain, isolation: "fixture")
        try await vault.reconcilePrivacy(intent, winning: item, archive: archive, password: "replacement-test-password", rpc: rpc)
        #expect(try await vault.privacyNotes().first?.depositHash == nil)
        #expect(try await vault.privacyNote(id: note.id, password: "replacement-test-password") == canonical)
    }
    @Test func proofSandboxDeniesUserDataWritesAndNetworking() throws {
        let node = runtimeDirectory.appendingPathComponent("node")
        guard FileManager.default.fileExists(atPath: node.path) else { return }
        let canary = FileManager.default.temporaryDirectory.appendingPathComponent("veil-sandbox-canary-" + UUID().uuidString)
        try Data("public-test-canary".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: canary) }
        let script = """
        const fs=require('node:fs'), net=require('node:net');
        try { fs.readFileSync(process.argv[1]); process.exit(31); } catch(e) { if(!['EPERM','EACCES'].includes(e.code))process.exit(32); }
        try { fs.writeFileSync(process.argv[1]+'-write','x'); process.exit(33); } catch(e) { if(!['EPERM','EACCES'].includes(e.code))process.exit(34); }
        const socket=net.connect({host:'1.1.1.1',port:443}); socket.on('connect',()=>process.exit(35)); socket.on('error',e=>process.exit(['EPERM','EACCES'].includes(e.code)?0:36)); setTimeout(()=>process.exit(37),3000);
        """
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", PrivacyProofRuntime.sandboxProfile(node: node, resources: runtimeDirectory), node.path, "--no-addons", "-e", script, canary.path]
        child.environment = ["PATH": "/usr/bin:/bin"]; child.currentDirectoryURL = runtimeDirectory
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit(); #expect(child.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: canary.path + "-write"))
    }
}

private struct PrivacyCancelReceipt: PrivateRequesting {
    let item: Activity
    func execute(_ request: PrivateRequest) async throws -> Data {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body!), value: JSONValue
        switch body["method"]?.string {
        case "eth_chainId": value = .string("0x1")
        case "eth_getTransactionReceipt": value = .object(["transactionHash": .string(item.hash), "from": .string(item.to), "status": .string("0x1"), "blockNumber": .string("0x1"), "blockHash": .string("0x" + String(repeating: "aa", count: 32))])
        case "eth_getBlockByNumber":
            guard case .array(let params) = body["params"] else { throw WalletError.invalid("Fixture RPC params") }
            value = .object(["number": params[0] == .string("latest") ? .string("0x10") : .string("0x1"), "hash": .string("0x" + String(repeating: "aa", count: 32))])
        default: throw WalletError.invalid("Unexpected privacy cancellation fixture RPC")
        }
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"]!, "result": value]))
    }
}
