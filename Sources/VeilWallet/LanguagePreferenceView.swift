import SwiftUI
import WalletCore

struct LanguagePreferenceView: View {
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Label(L("settings.language.title"), systemImage: "globe")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(WalletLanguage.allCases, id: \.rawValue) { language in
                        Button { WalletLanguage.select(language) } label: {
                            Text(language.name).font(.system(size: 12, weight: .medium))
                                .lineLimit(1).frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
                        }.buttonStyle(RowButtonStyle(selected: WalletLanguage.current == language, filled: true, cornerRadius: 7))
                            .accessibilityAddTraits(WalletLanguage.current == language ? [.isSelected] : [])
                            .interactionFrame("language.option." + language.rawValue)
                    }
                }.padding(4).frame(width: compact ? 200 : 240)
                    .background(Color.veilBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.veilBorder))
                    .accessibilityElement(children: .contain).accessibilityLabel(L("settings.language.title"))
                    .interactionFrame("language.control")
            }
            Text(L("settings.language.live_notice"))
                .font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
