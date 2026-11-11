import SwiftUI
import UIKit

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
                Text("This card isn't linked to a NEAR account yet. Copy its public key and link it on the Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let card = model.card {
                    SurfaceCard {
                        VStack(spacing: 12) {
                            InfoRow(label: "Card ID", value: card.cardUid)
                            InfoRow(label: "Public key", value: card.publicKeyHex)
                        }
                    }

                    Button("Copy public key") {
                        UIPasteboard.general.string = card.publicKeyHex
                    }
                    .font(.subheadline)
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

}
