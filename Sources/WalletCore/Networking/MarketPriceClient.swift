import Foundation

public struct MarketPriceClient: Sendable {
    public static let source = "DefiLlama"
    private let transport: any PrivateRequesting
    private let isolation: String
    public init(transport: any PrivateRequesting, isolation: String) { self.transport = transport; self.isolation = isolation }
    public func fetch(keys: [String], now: Date = Date()) async throws -> [MarketPriceSnapshot] {
        let sorted = Array(Set(keys)).sorted()
        guard sorted.count <= 1000, sorted.allSatisfy(Self.validKey) else { throw WalletError.invalid(L("message.invalid_or_excessive_price_query_identifiers")) }
        var output: [MarketPriceSnapshot] = []
        // A bounded sequential batch leaves Tor capacity for balances and sends.
        for start in stride(from: 0, to: sorted.count, by: 25) {
            try Task.checkCancellation()
            let batch = Array(sorted[start..<min(start + 25, sorted.count)])
            do {
                let url = URL(string: "https://coins.llama.fi/prices/current/" + batch.joined(separator: ","))!
                let data = try await transport.execute(PrivateRequest(url: url, isolation: isolation))
                try Task.checkCancellation()
                output += try Self.decode(data, requested: batch, now: now)
            } catch is CancellationError { throw CancellationError() }
            catch { output += batch.map { .init(key: $0, quote: nil, error: L("message.prices_are_unavailable_try_again_later"), now: now) } }
        }
        return output
    }
    static func validKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return (3...150).contains(key.count) && parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }
    }
    static func decode(_ data: Data, requested: [String], now: Date) throws -> [MarketPriceSnapshot] {
        struct Coin: Decodable {
            let price: Decimal?
            let timestamp: Int64?
            let confidence: Decimal?
            let decimals: Int?
            enum CodingKeys: String, CodingKey { case price, timestamp, confidence, decimals }
            init(from decoder: Decoder) throws {
                let values = try? decoder.container(keyedBy: CodingKeys.self)
                price = try? values?.decode(Decimal.self, forKey: .price)
                timestamp = try? values?.decode(Int64.self, forKey: .timestamp)
                confidence = try? values?.decode(Decimal.self, forKey: .confidence)
                decimals = try? values?.decode(Int.self, forKey: .decimals)
            }
        }
        struct Response: Decodable { let coins: [String: Coin] }
        guard data.count <= 2_000_000 else { throw WalletError.invalid(L("message.price_response_is_too_large")) }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return requested.map { key in
            guard let row = response.coins[key] else { return .init(key: key, quote: nil, error: L("message.no_usd_price_is_available_for_this_asset"), now: now) }
            guard let value = row.price, let units = try? USDValue.priceUnits(value), let timestamp = row.timestamp,
                  let confidence = row.confidence, confidence >= Decimal(string: "0.9")!, confidence <= 1,
                  timestamp > 0, timestamp <= Int64(now.timeIntervalSince1970) + 120,
                  timestamp >= Int64(now.timeIntervalSince1970) - 86400,
                  key.hasPrefix("coingecko:") || row.decimals.map({ (0...36).contains($0) }) == true else {
                return .init(key: key, quote: nil, error: L("message.price_data_lacks_a_valid_price_timestamp_decimals_or_confidence"), now: now)
            }
            let quote = MarketPrice(key: key, units: units, sourceTimestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)), fetchedAt: now, tokenDecimals: row.decimals)
            return .init(key: key, quote: quote, error: nil, now: now)
        }
    }
}
