import SwiftUI

/// Chooses the first screen from the setup stage: set up the card, link it to an account, then approvals.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.stage {
        case .loading:
            LoadingView()
        case .needsCard:
            SetupView()
        case .needsAccount:
            if let card = model.card {
                OnboardingView(card: card, baseURL: model.apiBaseURL)
            } else {
                SetupView()
            }
        case .ready:
            PendingListView()
        }
    }
}

private struct LoadingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            if let error = model.error {
                ReasonBanner(icon: "exclamationmark.triangle.fill", text: error, tone: Palette.danger)
                Button("Try again") {
                    Task { await model.refresh() }
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                ProgressView()
                Text("Connecting to Keyring…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
