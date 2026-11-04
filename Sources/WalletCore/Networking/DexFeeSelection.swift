import Foundation
import BigInt

extension EVMVenueClient {
    func bestFee(_ candidates: [UInt32], quote: @escaping @Sendable (UInt32) async throws -> BigUInt) async throws -> (amount: BigUInt, fee: UInt32) {
        guard !candidates.isEmpty, candidates.count <= 8 else { throw WalletError.invalid(L("message.invalid_number_of_dex_fee_candidates")) }
        var results: [(amount: BigUInt, fee: UInt32)] = []
        // At most 3 concurrent quotes; failed candidates never become zero quotes.
        for start in stride(from: 0, to: candidates.count, by: 3) {
            let batch = Array(candidates[start..<min(start + 3, candidates.count)])
            let values = await withTaskGroup(of: (BigUInt, UInt32)?.self) { group in
                for fee in batch { group.addTask { do { let amount = try await quote(fee); return amount > 0 ? (amount, fee) : nil } catch { return nil } } }
                var values: [(amount: BigUInt, fee: UInt32)] = []; for await value in group { if let value { values.append((value.0, value.1)) } }; return values
            }
            results += values
        }
        try Task.checkCancellation()
        guard let best = results.sorted(by: { $0.amount == $1.amount ? $0.fee < $1.fee : $0.amount > $1.amount }).first else { throw WalletError.invalid(L("message.no_quote_is_available_at_the_selected_fee_tiers_check")) }
        return best
    }
    func quoteLBAutomatic(_ venue: DexVenue, path: [String], amount: BigUInt, binStep: UInt32) async throws -> (amount: BigUInt, fee: UInt32) {
        if binStep > 0 { return (try await quoteLB(venue, path: path, amount: amount, binStep: binStep), binStep) }
        guard let factory = venue.factory, path.count == 2 else { throw WalletError.invalid(L("message.invalid_lb_factory_or_route")) }
        let data = try await rpc.readContract(ContractInvocation(contract: factory, signature: "getAllLBPairs(address,address)", arguments: path))
        guard data.count >= 64, BigUInt(data.prefix(32)) == 32, let count = Int(exactly: BigUInt(data[32..<64])), (1...64).contains(count), data.count == 64 + count * 128 else { throw WalletError.invalid(L("message.no_lb_pool_was_found_for_this_pair")) }
        var steps: [UInt32] = []
        for i in 0..<count {
            let row = Data(data[(64 + i * 128)..<(64 + (i + 1) * 128)])
            let fields = try ContractABI.uintWords(row, count: 4)
            if fields[3] == 0, let step = UInt32(exactly: fields[0]), step > 0, step <= 65535 { _ = try ContractABI.address(Data(row[32..<64])); steps.append(step) }
        }
        let candidates = Array(Set(steps).sorted().prefix(8))
        return try await bestFee(candidates) { try await quoteLB(venue, path: path, amount: amount, binStep: $0) }
    }
}
