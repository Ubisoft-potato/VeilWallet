import Foundation
import Darwin

/// Advisory process lease, held for the lifetime of this app instance. CLOEXEC
/// prevents helpers inheriting it; the OS releases it even after an app crash.
public final class WalletSessionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    public init() {}
    public func acquire(directory: URL) throws {
        try lock.withLock {
            if descriptor >= 0 { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("session.lock").path
            let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw WalletError.invalid(L("message.unable_to_create_the_local_wallet_process_lock")) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw WalletError.invalid(L("message.another_wallet_instance_is_using_this_data_directory_quit_that")) }
            descriptor = fd
        }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
