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
    @State private var pairCode = ""
    @State private var loadingPair = false

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

                    SectionTitle(text: "Agent pairing (optional)")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Run `npx keyring-agent-skills init` in your repo, then enter the code it prints. The agent key is added to this account and limited to request_spend.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("Pairing code", text: $pairCode)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                                Button {
                                    Task { await loadPair() }
                                } label: {
                                    if loadingPair {
                                        ProgressView()
                                    } else {
                                        Text("Load").font(.subheadline.weight(.semibold))
                                    }
                                }
                                .disabled(loadingPair || pairCode.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            if let pairing = model.pairing {
                                Divider()
                                InfoRow(label: "Agent key", value: pairing.agentPublicKey)
                                InfoRow(label: "Permission", value: "request_spend only")
                                InfoRow(
                                    label: "Policy",
                                    value: "\(NearAmount.near(pairing.policy.per_tx_max)) NEAR per payment, \(NearAmount.near(pairing.policy.daily_max)) NEAR daily"
                                )
                                if pairing.paired {
                                    InfoRow(label: "Already paired", value: pairing.account ?? "unknown account")
                                } else {
                                    Text("The card will authorize this agent when you create the account below.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Button {
                        showPin = true
                    } label: {
                        if onboarding.working {
                            ProgressView().tint(.white)
                        } else {
                            Text(model.pairing?.paired == false ? "Create account and pair agent" : "Create account and link")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(onboarding.working || !CardSession.isAvailable || model.pairing?.paired == true)

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
                    if let error = model.error {
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
                    await onboarding.link(pin: pin, pairing: model.pairing)
                    if let account = onboarding.account {
                        model.saveAccount(account)
                        if model.pairing != nil {
                            do {
                                try await model.completePair(account)
                            } catch {
                                model.error = "The account is ready, but pairing did not finish: "
                                    + AppModel.friendly(error)
                                    + " Open Settings → Agent → Pair an agent, load code "
                                    + (model.pairing?.code ?? "") + ", and tap Approve."
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            server = model.apiBaseURL.absoluteString
            if let pairing = model.pairing { pairCode = pairing.code }
        }
        .onChange(of: pairCode) { _, value in
            pairCode = value.uppercased()
        }
        .onChange(of: model.pairing?.code) { _, value in
            if let value { pairCode = value }
        }
    }

    private func loadPair() async {
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        loadingPair = true
        await model.loadPairing(code)
        loadingPair = false
        if let pairing = model.pairing { pairCode = pairing.code }
    }

    private func saveServer() {
        guard model.setAPIBaseURL(server), let url = APIClient.normalize(server) else { return }
        onboarding.setBaseURL(url)
        server = url.absoluteString
    }
}
