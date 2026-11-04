import SwiftUI
import AppKit
import WalletCore

private enum AssetImageCache {
    static let images = NSCache<NSString, NSImage>()
    static func image(_ key: String) -> NSImage? {
        if let image = images.object(forKey: key as NSString) { return image }
        guard let url = AssetArtwork.url(key), let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: key as NSString); return image
    }
}
struct AssetLogo: View {
    let chain: Chain
    var token: Token? = nil
    var size: CGFloat = 40
    var nativeAsset = false
    private var key: String? {
        if let token { return TokenCatalog.preset(for: token)?.logo }
        return nativeAsset ? AssetArtwork.nativeKey(chain) : AssetArtwork.networkKey(chain)
    }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let key, let image = AssetImageCache.image(key) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
                else { Circle().fill(Color.veilAccent.opacity(0.15)); Text(String((token?.symbol ?? chain.symbol).prefix(3))).font(.system(size: size * 0.25, weight: .bold)).foregroundStyle(Color.veilAccent) }
            }.frame(width: size, height: size).clipShape(Circle())
            if token != nil || nativeAsset {
                Group {
                    if let image = AssetImageCache.image(AssetArtwork.networkKey(chain)) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Circle().fill(Color.veilBackground); Text(String(chain.name.prefix(1))).font(.system(size: size * 0.17, weight: .bold)) }
                }.frame(width: size * 0.38, height: size * 0.38).clipShape(Circle()).background(Circle().fill(Color.veilBackground).padding(-2)).offset(x: 2, y: 2)
            }
        }.frame(width: size, height: size).accessibilityLabel(token?.symbol ?? chain.name)
    }
}
