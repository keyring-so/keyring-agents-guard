import SwiftUI

/// Shown after the card is set up but its key is not yet the approver of the account.
struct AccountPendingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.accent)
                Text("Card ready")
                    .font(.title2.weight(.bold))
                Text("This card's key is not yet the approver for \(AppConfig.account).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let card = model.card {
                    SurfaceCard {
                        VStack(spacing: 12) {
                            InfoRow(label: "Card ID", value: card.cardUid)
                            InfoRow(label: "Public key", value: Self.short(card.publicKeyHex))
                        }
                    }
                }

                ReasonBanner(
                    icon: "hourglass",
                    text: "Linking this card to a NEAR account is the next step. Approvals appear here once it's linked.",
                    tone: Palette.warning
                )

                Button("Check again") {
                    Task { await model.refresh() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
        }
        .background(Palette.canvas)
    }

    private static func short(_ hex: String) -> String {
        guard hex.count > 20 else { return hex }
        return "\(hex.prefix(10))…\(hex.suffix(8))"
    }
}
