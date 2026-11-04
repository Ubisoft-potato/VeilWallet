import SwiftUI
import WalletCore

struct NetworkSwitcher: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 9) { AssetLogo(chain: model.chain, size: 23); Text(model.chain.name).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(minHeight: 40).frame(maxWidth: 250).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(selected: showing, filled: true)).accessibilityLabel(L("message.switch_network") + model.chain.name).popover(isPresented: $showing, arrowEdge: .bottom) {
            NetworkSearchView { showing = false }.environmentObject(model).preferredColorScheme(.dark)
        }
    }
}
struct NetworkSearchView: View {
    var selected: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    @ViewState private var filter = 0
    @FocusState private var searchFocused: Bool
    private var chains: [Chain] {
        let fundedIDs = filter == 2 ? Set(model.assetQueries.filter { (model.snapshot($0)?.balance ?? 0) > 0 }.map { $0.chain.id }) : []
        return model.compatibleChains.filter { chain in
            let matches = search.isEmpty || [chain.name, chain.symbol, String(chain.id), chain.family.name].joined(separator: " ").localizedCaseInsensitiveContains(search)
            let funded = fundedIDs.contains(chain.id)
            return matches && (filter == 0 || (filter == 1 && (chain.isMainstreamEVM || (!chain.isEVM && chain.configured))) || (filter == 2 && funded) || (filter == 3 && chain.isTestnet))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(L("message.select_network")).font(.system(size: 19, weight: .semibold)); Spacer(); Text("\(chains.count)").foregroundStyle(.secondary) }
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(L("message.search_name_asset_or_chain_id"), text: $search).textFieldStyle(.plain).focused($searchFocused) }.padding(11).background(Color.veilBackground, in: RoundedRectangle(cornerRadius: 9))
            Picker(L("message.filter"), selection: $filter) { Text(L("message.all")).tag(0); Text(L("message.common")).tag(1); Text(L("message.with_assets")).tag(2); Text(L("message.testnets")).tag(3) }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(spacing: 5) {
                    if chains.isEmpty { ContentUnavailableView(L("message.no_matching_networks"), systemImage: "magnifyingglass") }
                    ForEach(chains) { chain in
                        Button {
                            guard !model.busy else { return }; model.chainID = chain.id; model.selectionChanged(); selected()
                        } label: {
                            HStack(spacing: 12) {
                                AssetLogo(chain: chain, size: 33)
                                VStack(alignment: .leading, spacing: 4) { Text(chain.name).font(.system(size: 13, weight: .medium)); Text(chain.isEVM ? "\(chain.symbol) · Chain ID \(chain.id)" : chain.family.name + " · " + chain.symbol).font(.system(size: 10)).foregroundStyle(.secondary) }
                                Spacer()
                                if chain.isTestnet { Text(L("message.testnets")).font(.system(size: 9)).foregroundStyle(.orange) }
                                if chain.id == model.chainID { Image(systemName: "checkmark").foregroundStyle(Color.veilAccent) }
                            }.padding(12).frame(maxWidth: .infinity, minHeight: 58).contentShape(Rectangle())
                        }.buttonStyle(RowButtonStyle(selected: chain.id == model.chainID)).disabled(model.busy)
                            .accessibilityValue(chain.id == model.chainID ? L("message.current_network") : "")
                    }
                }
            }.frame(height: 410)
        }.padding(20).frame(width: 400).background(Color.veilBackground).onAppear { searchFocused = true }
    }
}
