import Foundation
import CryptoKit
import BigInt

struct PrivacyCommitment: Decodable, Sendable { let commitment: String; let nullifierHash: String }
private struct ProofResponse<Value: Decodable>: Decodable { let result: Value }
private final class ProofCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func attach(_ process: Process) { lock.withLock { self.process = process; if cancelled, process.isRunning { process.terminate() } } }
    func cancel() { lock.withLock { cancelled = true; if let process, process.isRunning { process.terminate() } } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
private final class ProofProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProofCancellation?
    func set(_ value: ProofCancellation) { lock.withLock { current = value } }
    func clear(_ value: ProofCancellation) { lock.withLock { if current === value { current = nil } } }
    func cancel() { lock.withLock { current?.cancel() } }
}
public actor PrivacyProofRuntime {
    private struct Manifest: Decodable { let version: Int; let nodeVersion: String; let nodeSHA256: String; let files: [String: String] }
    private let directory: URL
    private var validated = false
    private var active: ProofCancellation?
    private nonisolated let processRegistry = ProofProcessRegistry()
    public init(directory: URL) { self.directory = directory }
    /// App termination and locking must not wait for an actor hop to kill a child.
    public nonisolated func stopImmediately() { processRegistry.cancel() }
    public func stop() { active?.cancel(); validated = false }
    private var resources: URL { FileManager.default.fileExists(atPath: directory.appendingPathComponent("node").path) ? directory : directory.appendingPathComponent("Contents/Resources") }
    private var node: URL { FileManager.default.fileExists(atPath: directory.appendingPathComponent("node").path) ? directory.appendingPathComponent("node") : directory.appendingPathComponent("Contents/MacOS/node") }
    private var manifestURL: URL {
        if resources == directory { return directory.appendingPathComponent("manifest.json") }
        // Outside the executable's own bundle: embedding its hash inside its
        // signed resource envelope would create a circular signing dependency.
        return directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/PrivacyRuntime-manifest.json")
    }
    func derive(_ material: PrivacyNoteMaterial) async throws -> PrivacyCommitment {
        let result: PrivacyCommitment = try await request(["action": .string("derive"), "preimage": .string(material.preimage)])
        guard Self.word(result.commitment), Self.word(result.nullifierHash) else { throw WalletError.invalid(L("message.invalid_locally_derived_note_outputs")) }; return result
    }
    public func publicFixtureProof() async throws -> PrivacyProof {
        try await proofRequest(action: "publicFixtureProof", preimage: String(repeating: "00", count: 62), leaves: [], recipient: "0x000000000000000000000000000000000000dEaD", relayer: "0x0000000000000000000000000000000000000000", fee: "0")
    }
    public func prove(note: PrivacyNoteMaterial, leaves: [String], recipient: String, relayer: String, fee: String) async throws -> PrivacyProof {
        try await proofRequest(action: "proof", preimage: note.preimage, leaves: leaves, recipient: recipient, relayer: relayer, fee: fee)
    }
    private func proofRequest(action: String, preimage: String, leaves: [String], recipient: String, relayer: String, fee: String) async throws -> PrivacyProof {
        guard Ethereum.validateAddress(recipient), Ethereum.validateAddress(relayer), leaves.count <= 1 << 20 else { throw WalletError.invalid(L("message.invalid_proof_recipient_or_event_count")) }
        let result: PrivacyProof = try await request(["action": .string(action), "preimage": .string(preimage), "leaves": .array(leaves.map(JSONValue.string)), "recipient": .string(recipient), "relayer": .string(relayer), "fee": .string(fee)])
        guard Self.word(result.root), Self.word(result.commitment), Self.word(result.nullifierHash), (try? Data(strictHex: result.proof).count) == 256, result.publicSignals.count == 6,
              let root = BigUIntCompat(result.root), let nullifier = BigUIntCompat(result.nullifierHash),
              result.publicSignals == [root, nullifier, BigUIntCompat(recipient) ?? "", BigUIntCompat(relayer) ?? "", fee, "0"] else { throw WalletError.invalid(L("message.proof_public_inputs_differ_from_the_approved_recipient_or_fees")) }
        return result
    }
    private static func word(_ value: String) -> Bool { value.hasPrefix("0x") && (try? Data(strictHex: value).count) == 32 }
    private func request<T: Decodable & Sendable>(_ object: [String: JSONValue]) async throws -> T {
        guard active == nil else { throw WalletError.invalid(L("message.a_local_proof_task_is_already_running")) }
        let cancellation = ProofCancellation(); active = cancellation
        processRegistry.set(cancellation)
        defer { active = nil; processRegistry.clear(cancellation) }
        if !validated { try verifyFiles(); validated = true }
        let body = try JSONEncoder().encode(JSONValue.object(object))
        guard body.count <= 100 * 1024 * 1024 else { throw WalletError.invalid(L("message.local_proof_input_is_too_large")) }
        let resourceURL = resources, executableURL = node
        let data: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let process = Process(), input = Pipe(), output = Pipe()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                        process.arguments = ["-p", Self.sandboxProfile(node: executableURL, resources: resourceURL), executableURL.path, "--no-addons", "--no-warnings", resourceURL.appendingPathComponent("main.cjs").path]
                        process.currentDirectoryURL = resourceURL
                        process.environment = ["PATH": "/usr/bin:/bin", "NODE_NO_WARNINGS": "1", "UV_THREADPOOL_SIZE": "1"]
                        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                        try process.run(); cancellation.attach(process)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { if process.isRunning { cancellation.cancel() } }
                        try input.fileHandleForWriting.write(contentsOf: body); try input.fileHandleForWriting.close()
                        var response = Data()
                        while let part = try output.fileHandleForReading.read(upToCount: 32_768), !part.isEmpty {
                            response.append(part)
                            if response.count > 65_536 { cancellation.cancel(); throw WalletError.invalid(L("message.local_proof_response_exceeds_the_limit")) }
                        }
                        process.waitUntilExit()
                        guard !cancellation.isCancelled, process.terminationStatus == 0 else { throw WalletError.invalid(L("message.local_proving_was_cancelled_timed_out_or_failed_no_external")) }
                        continuation.resume(returning: response)
                    } catch { cancellation.cancel(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return try JSONDecoder().decode(ProofResponse<T>.self, from: data).result
    }
    private func verifyFiles() throws {
        let manifestURL = self.manifestURL
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.nodeVersion == "24.22.2", (5...3000).contains(manifest.files.count), manifest.files["main.cjs"] != nil, manifest.files["artifacts/tornado.json"] != nil, manifest.files["artifacts/tornadoProvingKey.bin"] != nil else { throw WalletError.invalid(L("message.invalid_offline_proof_resource_manifest")) }
        func check(_ url: URL, hash: String) throws {
            guard hash.count == 64, try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))).hexString == hash else { throw WalletError.invalid(L("message.offline_proof_runtime_or_resource_verification_failed")) }
        }
        try check(node, hash: manifest.nodeSHA256)
        guard let iterator = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw WalletError.invalid(L("message.could_not_enumerate_offline_resources")) }
        var actual = Set<String>()
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw WalletError.invalid(L("message.offline_proof_resources_contain_a_symbolic_link")) }
            if values.isRegularFile == true, url != manifestURL, url != node { actual.insert(String(url.path.dropFirst(resources.path.count + 1))) }
        }
        guard actual == Set(manifest.files.keys) else { throw WalletError.invalid(L("message.offline_proof_resources_contain_undeclared_or_missing_files")) }
        for (path, hash) in manifest.files {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\\") else { throw WalletError.invalid(L("message.invalid_offline_proof_resource_path")) }
            try check(resources.appendingPathComponent(path), hash: hash)
        }
    }
    static func sandboxProfile(node: URL, resources: URL) -> String {
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var ancestors = Set<String>()
        for start in [node, resources] {
            var parent = start.deletingLastPathComponent()
            while parent.path != "/" { ancestors.insert(parent.path); parent.deleteLastPathComponent() }
        }
        let metadata = ancestors.sorted().map { "(literal " + quoted($0) + ")" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny mach-lookup)
        (deny file-read*)
        (deny file-write*)
        (deny process-exec)
        (allow process-exec (literal \(quoted(node.path))))
        (allow file-read-metadata \(metadata))
        (allow file-read* (literal "/") (literal \(quoted(node.path))) (subpath \(quoted(resources.path)))
          (subpath "/System") (subpath "/usr/lib") (subpath "/Library/Apple")
          (subpath "/private/var/db/dyld") (literal "/private/etc/localtime")
          (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/null"))
        (allow file-write* (literal "/dev/null"))
        """
    }
}

// Hex-to-decimal formatting uses the existing arbitrary precision library.
private func BigUIntCompat(_ hex: String) -> String? { (try? Data(strictHex: hex)).map { String(BigUInt($0)) } }
