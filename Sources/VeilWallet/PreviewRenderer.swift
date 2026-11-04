#if DEBUG
import AppKit
import SwiftUI
import ImageIO
import WalletCore

// Render only our own hierarchy with public BIP39 test vectors, without disk vault access or networking.
@MainActor enum PreviewRenderer {
    static func render(to destination: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel(previewMode: true)
        try capture(UnlockView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("unlock-language-preview.png"), size: NSSize(width: 1240, height: 820))
        let accounts = try MultichainCrypto.deriveAccounts(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let example = WalletSummary(name: L("message.public_test_vector_ui_preview"), address: accounts[0].address, kind: .mnemonic, accounts: accounts)
        model.wallets = [example]; model.walletID = example.id
        model.chainID = NetworkCatalog.nativeChains.first(where: { $0.family == .litecoin })!.id
        model.selectionChanged()
        try capture(RootView().environmentObject(model), to: destination, size: NSSize(width: 1240, height: 820))
        model.profileID = "ltc.mweb"; model.selectionChanged()
        try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("litecoin-mweb-preview.png"), size: NSSize(width: 1240, height: 820))
        try capture(ReceiveView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("litecoin-mweb-receive-preview.png"), size: NSSize(width: 580, height: 720))
        model.profileID = "ltc.segwit"; model.selectionChanged()
        for route in [Route.accounts, .networks] {
            model.route = route
            let name = route == .accounts ? "accounts-preview.png" : "networks-preview.png"
            try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent(name), size: NSSize(width: 1240, height: 820))
        }
        model.chainID = 8453; model.route = .assets; model.selectionChanged()
        try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("evm-base-preview.png"), size: NSSize(width: 1240, height: 820))
        try capture(AddWalletView(mode: 1).environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("import-preview.png"), size: NSSize(width: 580, height: 680))
        try capture(AddWalletView(mode: 1, previewAccounts: accounts).environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("import-addresses-preview.png"), size: NSSize(width: 580, height: 680))
        try capture(ContractCallView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("contract-preview.png"), size: NSSize(width: 650, height: 700))
        try capture(DexSwapView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("dex-preview.png"), size: NSSize(width: 650, height: 760))
        model.chainID = 56; model.selectionChanged()
        let usdt = TokenCatalog.all.first { $0.chainID == 56 && $0.symbol == "USDT" }!.token
        let approval = try ContractInvocation(contract: usdt.contract, signature: "approve(address,uint256)", arguments: [DexCatalog.find("pancake-v3-56")!.router, "1000000000000000000"])
        let approvalTX = try EVMTransaction(chainID: 56, nonce: 0, maxPriorityFee: 0, maxFee: 1_000_000_000, gasLimit: 60_000, to: approval.contract, value: 0, data: approval.data, mode: .legacy)
        let approvalPreview = TransactionPreview(transaction: approvalTX, sender: model.address!, recipient: approval.contract, amount: "0", symbol: "BNB", preparedAt: Date(), token: nil, additionalFees: .zero, purpose: .contract(approval))
        let approvalHash = "0x" + String(repeating: "33", count: 32)
        var approvalItem = Activity(walletID: example.id, chainID: 56, hash: approvalHash, to: approval.contract, amount: "0", symbol: "BNB")
        approvalItem.transaction = .evm(approvalPreview, groupID: approvalItem.id); approvalItem.transaction?.observation = TransactionObservation(.confirming)
        model.local.activities = [approvalItem]
        try capture(DexSwapView(previewApprovalHash: approvalHash).environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("bsc-approval-continuation-preview.png"), size: NSSize(width: 680, height: 820))
        try capture(EVMReviewView(submittedApproval: approvalPreview, hash: approvalHash).environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("bsc-approval-submitted-preview.png"), size: NSSize(width: 680, height: 820))
        model.chainID = TronAddress.chainID; model.selectionChanged()
        try capture(TronDexSwapView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("tron-dex-preview.png"), size: NSSize(width: 650, height: 760))
        try capture(BridgeView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("tron-bridge-preview.png"), size: NSSize(width: 650, height: 780))
        model.chainID = 1; model.selectionChanged()
        try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("bridge-assets-preview.png"), size: NSSize(width: 1240, height: 820))
        try capture(BridgeView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("bridge-preview.png"), size: NSSize(width: 650, height: 780))
        try capture(PrivacyPoolView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("privacy-pool-preview.png"), size: NSSize(width: 650, height: 780))
        model.chainID = NetworkCatalog.nativeChains.first(where: { $0.profileKeys.contains("cosmos") })!.id; model.selectionChanged()
        try capture(NativeSendView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("cosmos-send-preview.png"), size: NSSize(width: 650, height: 760))
        model.chainID = NetworkCatalog.nativeChains.first(where: { $0.family == .monero })!.id; model.selectionChanged()
        try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("monero-preview.png"), size: NSSize(width: 1240, height: 820))
        try capture(MoneroSendView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("monero-send-preview.png"), size: NSSize(width: 650, height: 760))
        model.chainID = 1; model.route = .activity; model.selectionChanged()
        let owner = model.address!, recipient = "0x000000000000000000000000000000000000dEaD"
        let tx = try EVMTransaction(chainID: 1, nonce: 6, maxPriorityFee: 2_000_000_000, maxFee: 30_000_000_000, gasLimit: 25_200, to: recipient, value: 1_000_000_000_000_000)
        let preview = TransactionPreview(transaction: tx, sender: owner, recipient: recipient, amount: "0.001", symbol: "ETH", preparedAt: Date(), token: nil, additionalFees: .zero, purpose: .transfer)
        var original = Activity(walletID: example.id, chainID: 1, hash: "0x" + String(repeating: "11", count: 32), to: recipient, amount: "0.001", symbol: "ETH")
        original.transaction = .evm(preview, groupID: original.id); original.transaction?.broadcastAttempts = 1; original.transaction?.observation = TransactionObservation(.broadcastUnknown, detail: L("message.public_ui_fixture_node_response_lost_original_hash_and_nonce"))
        var speed = Activity(walletID: example.id, chainID: 1, hash: "0x" + String(repeating: "22", count: 32), to: recipient, amount: "0.001", symbol: "ETH")
        speed.transaction = .evm(preview, groupID: original.id, action: .speedUp, parentID: original.id); speed.transaction?.broadcastAttempts = 1; speed.transaction?.observation = TransactionObservation(.pending)
        model.local.activities = [original, speed]
        try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("transactions-preview.png"), size: NSSize(width: 1240, height: 900))
        try capture(RootView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("transactions-small-preview.png"), size: NSSize(width: 1080, height: 740))
        try capture(EVMReviewView(preview: preview).environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("transaction-fees-preview.png"), size: NSSize(width: 650, height: 820))
        try capture(SettingsView().environmentObject(model).padding(28), to: destination.deletingLastPathComponent().appendingPathComponent("settings-refresh-preview.png"), size: NSSize(width: 920, height: 1280))
        model.route = .assets
        try capture(ScrollView { AssetsView(showZeroBalances: true).environmentObject(model).padding(28) }.background(Color.veilBackground), to: destination.deletingLastPathComponent().appendingPathComponent("portfolio-assets-preview.png"), size: NSSize(width: 1080, height: 1000))
        try capture(NetworkSearchView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("network-search-preview.png"), size: NSSize(width: 440, height: 560))
        try capture(WalletExperienceSettings().environmentObject(model).padding(24), to: destination.deletingLastPathComponent().appendingPathComponent("wallet-preferences-preview.png"), size: NSSize(width: 860, height: 660))
        model.chainID = TronAddress.chainID; model.selectionChanged()
        try capture(AddTokenView().environmentObject(model), to: destination.deletingLastPathComponent().appendingPathComponent("tron-tokens-preview.png"), size: NSSize(width: 650, height: 680))
        // Offline UI fixture only. Explicit labels distinguish illustrative
        // prices/balances from real wallet data and current market quotes.
        model.chainID = 56; model.local.chains = Chain.defaults.filter { [1,56,TronAddress.chainID].contains($0.id) || $0.family == .litecoin }; model.selectionChanged()
        model.local.assetBalances = []; model.local.marketPrices = []
        let examples: [(UInt64, String?, String, String?, TimeInterval)] = [(56,nil,"0.125","300",0),(56,"USDT","123.456","0.997",0),(56,"USDC","23.4",nil,0),(TronAddress.chainID,"USDT","50","0.998",0),(NetworkCatalog.nativeChains.first { $0.family == .litecoin }!.id,nil,"0.001","80",1800)]
        for (id,symbol,amount,price,age) in examples {
            guard let query = model.assetQueries.first(where: { $0.chain.id == id && $0.token?.symbol == symbol }) else { continue }
            model.local.assetBalances?.append(.init(query: query, balance: try Ethereum.parseUnits(amount, decimals: query.decimals)))
            if let price, let key = MarketPriceCatalog.key(chain: query.chain, token: query.token) {
                let quote = MarketPrice(key: key, units: try USDValue.priceUnits(Decimal(string: price)!), sourceTimestamp: Date().addingTimeInterval(-age), fetchedAt: Date(), tokenDecimals: query.token?.decimals)
                model.local.marketPrices?.append(.init(key: key, quote: quote, error: nil))
            }
        }
        model.restoreSelectedBalances()
        try capture(ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text(L("message.ui_fixture_example_prices_and_balances_not_live_prices_or")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
            AssetsView().environmentObject(model)
        }.padding(28) }.background(Color.veilBackground), to: destination.deletingLastPathComponent().appendingPathComponent("usd-portfolio-preview.png"), size: NSSize(width: 1080, height: 1360))
        // Public documentation capture: the same native hierarchy, an explicit
        // fixture banner, and no live vault, persistence, signing or networking.
        try capture(VStack(spacing: 0) {
            Text(L("message.ui_fixture_example_prices_and_balances_not_live_prices_or"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                .padding(12).frame(maxWidth: .infinity).background(Color.veilPanel)
            RootView().environmentObject(model)
        }, to: destination.deletingLastPathComponent().appendingPathComponent("readme-overview.png"), size: NSSize(width: 1280, height: 1000))
    }
    private static func capture<V: View>(_ root: V, to destination: URL, size: NSSize) throws {
        let view = NSHostingView(rootView: root.environment(\.locale, WalletLanguage.current.locale).preferredColorScheme(.dark).buttonStyle(SecondaryButton()).disclosureGroupStyle(WalletDisclosureStyle()).frame(width: size.width, height: size.height).background(Color.veilBackground))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Export pixels only; do not carry AppKit EXIF/text properties into
        // public documentation assets.
        guard let pixels = bitmap.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let encoded = CFDataCreateMutable(nil, 0),
              let output = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        canvas.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard let exported = canvas.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, exported, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        // ImageIO may synthesize EXIF even for fresh pixels. Retain only PNG
        // image/color chunks verbatim, including their original CRCs and IDAT.
        let png = Data(bytes: CFDataGetBytePtr(encoded)!, count: CFDataGetLength(encoded))
        var clean = Data(png.prefix(8)), offset = 8
        let imageChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP", "cICP"]
        while offset < png.count {
            guard offset + 12 <= png.count else { throw CocoaError(.fileWriteUnknown) }
            let length = png[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + length + 12
            guard end <= png.count else { throw CocoaError(.fileWriteUnknown) }
            let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
            if imageChunks.contains(type) { clean.append(png[offset..<end]) }
            offset = end
        }
        try clean.write(to: destination, options: .atomic)
        window.orderOut(nil)
    }
}
#endif
