import Foundation
import CPrivacyTransport

public struct PrivateRequest: Sendable {
    public enum MediaType: Int32, Sendable { case json = 0, text = 1, aptosBCS = 2 }
    public let url: URL
    public let body: Data?
    public let isolation: String
    public let mediaType: MediaType
    public init(url: URL, body: Data? = nil, isolation: String, mediaType: MediaType = .json) throws {
        try Self.validate(url)
        self.url = url; self.body = body; self.isolation = isolation; self.mediaType = mediaType
    }
    public static func validate(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.contains("."), host.count <= 253,
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              host != "localhost", host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              host.split(separator: ".").contains(where: { $0.contains(where: { $0.isLetter }) }) else {
            throw WalletError.invalid(L("message.endpoints_require_an_https_domain_and_port_443_local_hosts"))
        }
    }
}
public protocol PrivateRequesting: Sendable { func execute(_ request: PrivateRequest) async throws -> Data }
private final class Cancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let value = veil_cancel_create() else { throw WalletError.invalid(L("message.could_not_allocate_a_network_task")) }; pointer = value
    }
    func cancel() { veil_cancel_set(pointer) }
    deinit { veil_cancel_destroy(pointer) }
}
public final class NetworkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16?
    private var generation = UUID()
    private var requests: [UUID: Cancellation] = [:]
    public init() {}
    public var isReady: Bool { lock.withLock { port != nil } }
    public func moneroProxyPort() throws -> UInt16 { try lock.withLock { guard let port else { throw WalletError.networkBlocked }; return port } }
    public func open(port: UInt16) { lock.withLock { self.port = port; generation = UUID() } }
    public func close() {
        lock.withLock {
            port = nil; generation = UUID()
            requests.values.forEach { $0.cancel() }
        }
    }
    fileprivate func acquire(_ token: Cancellation, id: UUID) throws -> (UInt16, UUID) {
        try lock.withLock {
            guard let port else { throw WalletError.networkBlocked }
            requests[id] = token; return (port, generation)
        }
    }
    fileprivate func finish(_ id: UUID, generation expected: UUID) throws {
        try lock.withLock {
            requests[id] = nil
            guard generation == expected, port != nil else { throw WalletError.networkBlocked }
        }
    }
    fileprivate func release(_ id: UUID) { _ = lock.withLock { requests.removeValue(forKey: id) } }
}
public struct TorTransport: PrivateRequesting {
    private let gate: NetworkGate
    public init(gate: NetworkGate) { self.gate = gate }
    public func execute(_ request: PrivateRequest) async throws -> Data {
        try Task.checkCancellation()
        guard let ca = Bundle.module.url(forResource: "cacert", withExtension: "pem") else { throw WalletError.invalid(L("message.bundled_ca_certificates_are_missing_networking_is_blocked")) }
        let cancellation = try Cancellation(); let id = UUID()
        let (port, generation) = try gate.acquire(cancellation, id: id)
        defer { gate.release(id) }
        return try await withTaskCancellationHandler {
            // curl_easy_perform blocks. Keep it off Swift's cooperative executor so
            // concurrent fee quotes cannot starve their own cancellation/timer tasks.
            let response: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let response = request.url.absoluteString.withCString { url in request.isolation.withCString { identity in ca.path.withCString { caPath in
                            if let body = request.body {
                                return body.withUnsafeBytes { data in
                                    veil_request_typed(url, data.bindMemory(to: UInt8.self).baseAddress, body.count, port, identity, caPath, cancellation.pointer, request.mediaType.rawValue)
                                }
                            }
                            return veil_request_typed(url, nil, 0, port, identity, caPath, cancellation.pointer, request.mediaType.rawValue)
                        } } }
                        defer { veil_response_free(response) }
                        guard response.code == 0 else { throw WalletError.transport(Int(response.code)) }
                        guard (200...299).contains(response.status) else { throw WalletError.http(Int(response.status)) }
                        continuation.resume(returning: response.bytes.map { Data(bytes: $0, count: response.length) } ?? Data())
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            try gate.finish(id, generation: generation)
            return response
        } onCancel: { cancellation.cancel() }
    }
}
