import Testing
import Foundation
import Network
@testable import WalletCore

final class PrivacyTests {
    @Test func testURLPolicy() throws {
        for string in ["http://example.com", "https://127.0.0.1", "https://192.168.1.1", "https://localhost", "https://node.local", "https://[::1]", "https://user:pass@example.com", "https://example.com:8545", "file:///tmp/test", "https://example.com/#fragment"] {
            expectThrows(try PrivateRequest.validate(URL(string: string)!))
        }
        expectNoThrow(try PrivateRequest.validate(URL(string: "https://ethereum-rpc.publicnode.com")!))
    }
    @Test func testNoTorMeansNoRequest() async throws {
        let transport = TorTransport(gate: NetworkGate())
        do {
            _ = try await transport.execute(PrivateRequest(url: URL(string: "https://example.com")!, isolation: "test"))
            Issue.record("Request was allowed")
        } catch { expectEqual(error as? WalletError, .networkBlocked) }
    }
    @MainActor @Test func testTorConfiguration() throws {
        let config = try TorController.configuration(dataDirectory: URL(fileURLWithPath: "/tmp/veil-test"), port: 19050, bundle: URL(fileURLWithPath: "/tmp/tor"), bridges: [])
        for directive in ["SafeSocks 1", "DNSPort 0", "ControlPort 0", "IsolateSOCKSAuth", "SafeLogging 1", "127.0.0.1:19050"] { expectTrue(config.contains(directive)) }
        let packaged = try TorController.configuration(dataDirectory: URL(fileURLWithPath: "/tmp/veil-test"), port: 19050, bundle: URL(fileURLWithPath: "/tmp/TorRuntime.bundle"), bridges: ["obfs4 192.0.2.1:443 ABCDEF0123456789ABCDEF0123456789ABCDEF01 cert=example iat-mode=0"])
        expectTrue(packaged.contains("TorRuntime.bundle/Contents/Resources/data/geoip"))
        expectTrue(packaged.contains("TorRuntime.bundle/Contents/MacOS/lyrebird"))
        expectThrows(try TorController.configuration(dataDirectory: URL(fileURLWithPath: "/tmp/x"), port: 19050, bundle: URL(fileURLWithPath: "/tmp/tor"), bridges: ["obfs4 bridge.example.com:443 ABCDEF0123456789ABCDEF0123456789ABCDEF01 cert=example"]))
        expectThrows(try TorController.configuration(dataDirectory: URL(fileURLWithPath: "/tmp/x"), port: 19050, bundle: URL(fileURLWithPath: "/tmp/tor"), bridges: ["obfs4 valid\nSocksPort 0"]))
    }
    @Test func testSOCKSHostnameDoesNotFallBackToLocalDNS() async throws {
        // A .invalid domain cannot resolve locally. A SOCKS server must still receive
        // its original hostname, with ATYP=3, before any TLS traffic is attempted.
        let server = try SOCKSProbe()
        defer { server.stop() }
        let port = try await server.start()
        let gate = NetworkGate(); gate.open(port: port)
        let transport = TorTransport(gate: gate)
        let host = "veil-privacy-test.invalid"
        setenv("NO_PROXY", "*", 1)
        defer { unsetenv("NO_PROXY") }
        do { _ = try await transport.execute(PrivateRequest(url: URL(string: "https://\(host)")!, isolation: "wallet-isolation")); Issue.record("Probe must reject connection") } catch {}
        let captured = try await server.hostname()
        expectEqual(captured, host)
    }
    @Test(arguments: [true, false]) func concurrentBlockedRequestsDoNotStarveCancellation(closeGate: Bool) async throws {
        let server = try SOCKSProbe(holdConnections: true)
        defer { server.stop() }
        let gate = NetworkGate(); gate.open(port: try await server.start())
        defer { gate.close() }
        let transport = TorTransport(gate: gate), start = ContinuousClock.now
        let pending = Task {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<32 {
                    group.addTask {
                        do { _ = try await transport.execute(PrivateRequest(url: URL(string: "https://veil-cancellation-test.invalid")!, isolation: "cancel-\(i)")); Issue.record("Stalled TLS request succeeded") } catch {}
                    }
                }
                await group.waitForAll()
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        if closeGate { gate.close() } else { pending.cancel() }
        await pending.value
        #expect(start.duration(to: .now) < .seconds(8))
        #expect(gate.isReady == !closeGate)
    }
}
final class SOCKSProbe: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "veil.test.socks")
    private var captured: String?
    private let lock = NSLock()
    private let version: Int
    private let holdConnections: Bool
    private var held: [NWConnection] = []
    init(version: Int = 5, holdConnections: Bool = false) throws { self.version = version; self.holdConnections = holdConnections; listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else { return }
                    self?.listener.stateUpdateHandler = nil; continuation.resume(returning: port)
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                if self?.holdConnections == true { self?.lock.withLock { self?.held.append(connection) } }
                connection.start(queue: self?.queue ?? .global())
                self?.read(connection, count: 2) { head in
                    guard head.count == 2 else { connection.cancel(); return }
                    if self?.version == 4 {
                        guard head == Data([4, 1]) else { connection.cancel(); return }
                        self?.read(connection, count: 6) { address in
                            guard address.count == 6, address.suffix(4) == Data([0, 0, 0, 1]) else { connection.cancel(); return }
                            self?.readCString(connection) { _ in
                                self?.readCString(connection) { host in
                                    self?.lock.withLock { self?.captured = host }
                                    connection.send(content: Data([0, 91, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in connection.cancel() })
                                }
                            }
                        }
                        return
                    }
                    self?.read(connection, count: Int(head[1])) { _ in
                        // Select no-auth: domain forwarding must work even without auth negotiation.
                        connection.send(content: Data([5, 0]), completion: .contentProcessed { _ in
                            self?.read(connection, count: 5) { request in
                                guard request.count == 5, request[3] == 3 else { connection.cancel(); return }
                                self?.read(connection, count: Int(request[4]) + 2) { data in
                                    self?.lock.withLock { self?.captured = String(data: data.dropLast(2), encoding: .utf8) }
                                    let hold = self?.holdConnections == true
                                    connection.send(content: Data([5, hold ? 0 : 4, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in if !hold { connection.cancel() } })
                                }
                            }
                        })
                    }
                }
            }
            listener.start(queue: queue)
        }
    }
    private func read(_ connection: NWConnection, count: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in completion(data ?? Data()) }
    }
    private func readCString(_ connection: NWConnection, data: Data = Data(), completion: @escaping (String) -> Void) {
        guard data.count <= 253 else { connection.cancel(); return }
        read(connection, count: 1) { byte in
            guard let first = byte.first else { connection.cancel(); return }
            if first == 0 { completion(String(decoding: data, as: UTF8.self)) }
            else { self.readCString(connection, data: data + byte, completion: completion) }
        }
    }
    func hostname() async throws -> String {
        for _ in 0..<100 {
            if let value = lock.withLock({ captured }) { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WalletError.invalid("SOCKS 未接收到目标域名")
    }
    func stop() { listener.cancel(); lock.withLock { held.forEach { $0.cancel() }; held.removeAll() } }
}
