import Foundation
import Combine
import Darwin

public enum TorState: Equatable {
    case stopped, starting(Int), ready, failed(String)
    public var label: String {
        switch self {
        case .stopped: return L("message.network_blocked")
        case .starting(let progress): return L("message.connecting_to_tor_0", progress)
        case .ready: return L("message.tor_connected")
        case .failed(let reason): return reason
        }
    }
}
@MainActor public final class TorController: ObservableObject {
    @Published public private(set) var state: TorState = .stopped
    public let gate: NetworkGate
    private var process: Process?
    private var output: Pipe?
    private var pending = ""
    private var startupTimeout: Task<Void, Never>?
    private let bundle: URL
    private let dataDirectory: URL
    private var runID = UUID()
    public init(gate: NetworkGate, bundle: URL, dataDirectory: URL) {
        self.gate = gate; self.bundle = bundle; self.dataDirectory = dataDirectory
    }
    public func start(bridges: [String] = []) {
        guard process == nil else { return }
        gate.close(); pending = ""; state = .starting(0)
        do {
            let executable = bundle.appendingPathComponent(bundle.pathExtension == "bundle" ? "Contents/MacOS/tor" : "tor/tor")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw WalletError.invalid(L("message.bundled_tor_was_not_found_run_scripts_fetch_tor_sh"))
            }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let port = UInt16.random(in: 20000...60000)
            let config = try Self.configuration(dataDirectory: dataDirectory, port: port, bundle: bundle, bridges: bridges)
            let configURL = dataDirectory.appendingPathComponent("torrc")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            let process = Process(); let pipe = Pipe(); let currentRun = UUID(); runID = currentRun
            process.executableURL = executable
            process.arguments = ["-f", configURL.path, "--__OwningControllerProcess", String(ProcessInfo.processInfo.processIdentifier)]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": dataDirectory.path]
            process.currentDirectoryURL = executable.deletingLastPathComponent()
            process.standardOutput = pipe; process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    guard let self, self.runID == currentRun else { return }
                    self.consume(text, port: port)
                }
            }
            process.terminationHandler = { [weak self, gate] _ in
                gate.close() // Immediate, independent of the UI queue.
                Task { @MainActor in
                    guard let self, self.runID == currentRun else { return }
                    self.output?.fileHandleForReading.readabilityHandler = nil
                    self.process = nil; self.output = nil; self.startupTimeout?.cancel()
                    if self.state != .stopped { self.state = .failed(L("message.tor_exited_network_blocked")) }
                }
            }
            self.process = process; output = pipe
            try process.run()
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled, let self, self.runID == currentRun else { return }
                if case .starting = self.state { self.stop(); self.state = .failed(L("message.tor_connection_timed_out_configure_bridges_and_try_again")) }
            }
        } catch {
            process = nil; output?.fileHandleForReading.readabilityHandler = nil; output = nil
            state = .failed(error.localizedDescription); gate.close()
        }
    }
    public func stop() {
        gate.close(); state = .stopped; runID = UUID(); startupTimeout?.cancel(); startupTimeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; output = nil; pending = ""
    }
    private func consume(_ text: String, port: UInt16) {
        pending += text
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]); pending = String(pending[pending.index(after: newline)...])
            if let range = line.range(of: "Bootstrapped "), let percent = line[range.upperBound...].split(separator: "%").first, let value = Int(percent), (0...100).contains(value) {
                if value == 100, process?.isRunning == true {
                    state = .ready; gate.open(port: port); startupTimeout?.cancel()
                } else { state = .starting(value) }
            }
        }
        if pending.count > 8192 { pending = "" }
    }
    public static func configuration(dataDirectory: URL, port: UInt16, bundle: URL, bridges: [String]) throws -> String {
        func quoted(_ url: URL) throws -> String {
            guard !url.path.contains("\n"), !url.path.contains("\r"), !url.path.contains("\"") else { throw WalletError.invalid(L("message.the_tor_path_contains_invalid_characters")) }
            return "\"\(url.path)\""
        }
        let resources = bundle.pathExtension == "bundle" ? bundle.appendingPathComponent("Contents/Resources") : bundle
        let plugin = bundle.appendingPathComponent(bundle.pathExtension == "bundle" ? "Contents/MacOS/lyrebird" : "tor/pluggable_transports/lyrebird")
        var lines = [
            "ClientOnly 1", "DataDirectory \(try quoted(dataDirectory))",
            "SocksPort 127.0.0.1:\(port) IsolateSOCKSAuth",
            "SafeSocks 1", "TestSocks 0", "ClientRejectInternalAddresses 1", "ClientDNSRejectInternalAddresses 1",
            "DNSPort 0", "TransPort 0", "ControlPort 0", "AvoidDiskWrites 1", "SafeLogging 1", "Log notice stdout",
            "GeoIPFile \(try quoted(resources.appendingPathComponent("data/geoip")))",
            "GeoIPv6File \(try quoted(resources.appendingPathComponent("data/geoip6")))"
        ]
        if !bridges.isEmpty {
            guard bridges.count <= 16, bridges.allSatisfy(Self.validBridge) else {
                throw WalletError.invalid(L("message.each_bridge_must_be_one_line_with_obfs4_an_ip"))
            }
            lines += ["UseBridges 1", "ClientTransportPlugin obfs4 exec \(try quoted(plugin))"]
            lines += bridges.map { "Bridge \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
    private static func validBridge(_ line: String) -> Bool {
        guard line.count < 2048, !line.contains("\n"), !line.contains("\r"),
              line.utf8.allSatisfy({ (32...126).contains($0) && $0 != 34 && $0 != 35 && $0 != 92 }) else { return false }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, fields[0] == "obfs4", fields[2].count == 40,
              fields[2].allSatisfy(\.isHexDigit) else { return false }
        let endpoint = String(fields[1])
        guard let separator = endpoint.lastIndex(of: ":"), let port = UInt16(endpoint[endpoint.index(after: separator)...]), port > 0 else { return false }
        var host = String(endpoint[..<separator])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var ipv4 = in_addr(); var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

}
