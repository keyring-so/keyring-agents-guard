import SwiftUI
import UIKit

/// One-time link: the sponsor creates the account with the card key, then the card signs
/// register + deposit. The phone never sends a secret.
struct OnboardingView: View {
    let card: CardRecord
    @EnvironmentObject private var model: AppModel
    @StateObject private var onboarding: OnboardingModel
    @State private var server = ""
    @State private var showPin = false

    init(card: CardRecord, baseURL: URL) {
        self.card = card
        _onboarding = StateObject(wrappedValue: OnboardingModel(card: card, baseURL: baseURL))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Palette.accent)
                    Text("Card ready")
                        .font(.title2.weight(.bold))
                    Text("Create a NEAR account for this card. The sponsor creates it with your card's key, then your card signs registering with the shared policy and funding your balance.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

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

                    Button {
                        showPin = true
                    } label: {
                        if onboarding.working {
                            ProgressView().tint(.white)
                        } else {
                            Text("Create account and link")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(onboarding.working || !CardSession.isAvailable)

                    if !CardSession.isAvailable {
                        ReasonBanner(
                            icon: "iphone.slash",
                            text: "NFC is not available in the Simulator. Use a physical iPhone.",
                            tone: Palette.warning
                        )
                    }

                    if let status = onboarding.status {
                        Text(status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let error = onboarding.error {
                        ReasonBanner(icon: "xmark.octagon.fill", text: error, tone: Palette.danger)
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("API server")
                                .font(.subheadline.weight(.semibold))
                            HStack {
                                TextField("http://192.168.1.20:8787", text: $server)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.callout)
                                Button("Save") {
                                    saveServer()
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            Text("Use the Mac's LAN address on a device. The simulator uses 127.0.0.1.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
            }
            .background(Palette.canvas)
            .navigationTitle("Link account")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showPin) {
            PinSheet(decision: .onboard) { pin in
                showPin = false
                Task {
                    await onboarding.link(pin: pin)
                    if let account = onboarding.account {
                        model.saveAccount(account)
                    }
                }
            }
        }
        .onAppear { server = model.apiBaseURL.absoluteString }
    }

    private func saveServer() {
        guard model.setAPIBaseURL(server), let url = APIClient.normalize(server) else { return }
        onboarding.setBaseURL(url)
        server = url.absoluteString
    }
}
