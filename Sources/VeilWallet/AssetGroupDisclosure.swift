import SwiftUI
import WalletCore

struct AssetGroupDisclosure<Holdings: View>: View {
    let group: PortfolioAssetGroup
    let summary: PortfolioAssetGroupSummary
    let updating: Bool
    @Binding var expanded: Bool
    @ViewBuilder var holdings: Holdings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 15) {
                    let first = group.holdings[0]
                    AssetLogo(chain: first.chain, token: first.token, size: 40, nativeAsset: first.token == nil, showNetworkBadge: false)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(group.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        HStack(spacing: 7) {
                            HStack(spacing: -4) {
                                ForEach(Array(group.networks.prefix(4))) { chain in
                                    AssetLogo(chain: chain, size: 17).background(Circle().fill(Color.veilPanel).padding(-2))
                                }
                            }.accessibilityHidden(true)
                            Text(L("assets.group.scope", group.networks.count, group.holdings.count)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    price.frame(width: 120, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(summary.displayBalance).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.65)
                        Text(summary.valuation.displayTotal).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        if updating { Text(L("message.updating")).foregroundStyle(Color.veilAccent) }
                        else if summary.unknownBalances > 0 { Text(L("assets.group.unknown_balances", summary.unknownBalances)).foregroundStyle(.orange) }
                        else if summary.historicalBalances > 0 || summary.valuation.historicalHoldings > 0 { Text(L("assets.group.historical")).foregroundStyle(.orange) }
                        else if summary.valuation.unpricedHoldings > 0 { Text(L("assets.group.partial_value")).foregroundStyle(.orange) }
                    }.font(.system(size: 10)).frame(width: 165, alignment: .trailing)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.veilAccent)
                        .rotationEffect(.degrees(expanded ? 180 : 0)).frame(width: 30, height: 30)
                        .background(Color.veilAccent.opacity(0.08), in: Circle())
                }.padding(20).frame(minHeight: 98).contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(selected: expanded, cornerRadius: 0))
                .accessibilityLabel(L("assets.group.accessibility", group.symbol, group.networks.count))
                .accessibilityValue(expanded ? L("disclosure.collapse") : L("disclosure.expand"))
                .help(L("assets.group.toggle_hint"))
                .interactionFrame("assets.group." + group.symbol)
            if expanded {
                VStack(spacing: 0) { holdings }
                    .padding(.leading, 22)
                    .background(Color.veilBackground.opacity(0.4))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.veilAccent.opacity(0.2)).frame(width: 2).padding(.leading, 19).padding(.vertical, 14).allowsHitTesting(false) }
                    .interactionFrame("assets.holdings." + group.symbol)
                    .transition(.opacity)
            }
        }
    }
    private var price: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let minimum = summary.minimumPrice, let maximum = summary.maximumPrice {
                if minimum == maximum {
                    Text(USDValue.formatted(minimum, unitPrice: true))
                } else {
                    Text(USDValue.formatted(minimum, unitPrice: true) + " – " + USDValue.formatted(maximum, unitPrice: true))
                }
            } else { Text("—") }
            Text(summary.missingPrices > 0 ? L("assets.group.partial_prices") : (summary.historicalPrices ? L("assets.group.historical_prices") : L("assets.group.network_prices")))
                .font(.system(size: 9)).foregroundStyle(summary.missingPrices > 0 || summary.historicalPrices ? Color.orange : .secondary)
        }.font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.primary).lineLimit(2).minimumScaleFactor(0.75)
    }
}
