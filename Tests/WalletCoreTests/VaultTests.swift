import Testing
import Foundation
@testable import WalletCore

final class VaultTests {
    @Test func testEncryptedLifecycleAndFreshAuthentication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vault.json")
        let vault = VaultStore(url: url)
        let password = "test-only-long-password"
        try await vault.create(password: password)
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let wallet = try await vault.addMnemonic(name: "Test", phrase: phrase)
        let bytes = try Data(contentsOf: url)
        expectFalse(String(decoding: bytes, as: UTF8.self).contains("abandon"))
        expectFalse(String(decoding: bytes, as: UTF8.self).contains(wallet.address))
        await vault.lock()
        do { _ = try await vault.summaries(); Issue.record("Locked access") } catch { expectEqual(error as? WalletError, .locked) }
        do { _ = try await vault.unlock(password: "wrong"); Issue.record("Wrong password") } catch { expectEqual(error as? WalletError, .vaultAuthentication) }
        let summaries = try await vault.unlock(password: password)
        expectEqual(summaries, [wallet])
        do { _ = try await vault.reveal(walletID: wallet.id, password: "wrong"); Issue.record("Reveal accepted wrong password") } catch {}
        let backup = try await vault.reveal(walletID: wallet.id, password: password)
        expectEqual(backup.material, phrase)
        var damaged = bytes; damaged[damaged.count / 2] ^= 1; try damaged.write(to: url)
        do { _ = try await vault.unlock(password: password); Issue.record("Tampering accepted") } catch {}
    }
    @Test func testWatchWalletCannotSignAndDuplicatePrevention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultStore(url: directory.appendingPathComponent("vault.json"))
        let password = "test-only-long-password"
        try await vault.create(password: password)
        let wallet = try await vault.addWatch(name: "Observe", address: "0x000000000000000000000000000000000000dEaD")
        expectFalse(wallet.canSign)
        do { _ = try await vault.addWatch(name: "Duplicate", address: wallet.address); Issue.record("Duplicate accepted") } catch {}
        do { _ = try await vault.reveal(walletID: wallet.id, password: password); Issue.record("Watch wallet has secret") } catch {}
    }
}

extension VaultTests {
    @Test func passwordRotationAndWalletRemoval() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = VaultStore(url: dir.appendingPathComponent("vault.json"))
        let old = "old-password-long-enough", new = "new-password-long-enough"
        try await vault.create(password: old)
        let record = try await vault.addWatch(name: "Before", address: "0x000000000000000000000000000000000000dEaD")
        try await vault.rename(walletID: record.id, name: "After")
        try await vault.changePassword(current: old, replacement: new)
        await vault.lock()
        do { _ = try await vault.unlock(password: old); Issue.record("Old password still works") } catch {}
        let wallets = try await vault.unlock(password: new)
        #expect(wallets.first?.name == "After")
        do { try await vault.remove(walletID: record.id, password: old); Issue.record("Removal accepted old password") } catch {}
        try await vault.remove(walletID: record.id, password: new)
        let remaining = try await vault.summaries()
        #expect(remaining.isEmpty)
    }
}
