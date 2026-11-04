import SwiftUI

/// First-run setup. The app shows nothing else until the card is set up on this phone.
struct SetupView: View {
    @StateObject private var setup = CardSetupModel()
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch setup.step {
                    case .intro: intro
                    case .check: checkStep
                    case .pin: pinStep
                    case .words: wordsStep
                    case .tap: tapStep
                    case .done: doneStep
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas)
            .navigationTitle("Set up your card")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(spacing: 22) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 52))
                .foregroundStyle(Palette.accent)
            Text("Welcome")
                .font(.title2.weight(.bold))
            Text("Your Keyring card holds the wallet's key. Before the agent can spend, set the card up once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    StepRow(number: 1, text: "Tap your card to check it.")
                    StepRow(number: 2, text: "Choose a 6-digit PIN on this phone.")
                    StepRow(number: 3, text: "Write down 12 recovery words.")
                    StepRow(number: 4, text: "Tap the card again to load the wallet.")
                }
            }

            Button("Start") { setup.step = .check }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var checkStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 52))
                .foregroundStyle(Palette.accent)
            Text("Check your card")
                .font(.title3.weight(.semibold))
            Text("Hold the card to the top of the iPhone. Nothing is written to the card in this step.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = setup.error {
                ReasonBanner(icon: "xmark.octagon.fill", text: error, tone: Palette.danger)
            }

            tapButton(idle: "Tap card to check") {
                await setup.checkCard()
            }
        }
    }

    private var pinStep: some View {
        VStack(spacing: 22) {
            Text(setup.pinPrompt)
                .font(.title3.weight(.semibold))
            Text("The card locks after 3 wrong tries. Pick a PIN you will remember.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            PinField(pin: $setup.pin)
                .padding(.vertical, 8)

            if let error = setup.error {
                ReasonBanner(icon: "xmark.octagon.fill", text: error, tone: Palette.danger)
            }

            Button("Next") { setup.submitPin() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(setup.pin.count != AppConfig.cardPINLength)
        }
    }

    private var wordsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your recovery words")
                .font(.title3.weight(.semibold))

            ReasonBanner(
                icon: "exclamationmark.triangle.fill",
                text: "Write these 12 words on paper, in order. They are the only backup of this wallet. Never share them, and never type them into a website.",
                tone: Palette.warning
            )

            SurfaceCard {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(Array(setup.words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(word)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Toggle("I have written the words down", isOn: $setup.wroteDown)
                .font(.subheadline)

            Button("Continue") { setup.step = .tap }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!setup.wroteDown)
        }
    }

    private var tapStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 52))
                .foregroundStyle(Palette.accent)
            Text("Hold your card to the top of the iPhone")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Your PIN goes to the card over NFC. This tap sets the PIN and loads the wallet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = setup.error {
                ReasonBanner(icon: "xmark.octagon.fill", text: error, tone: Palette.danger)
            }

            tapButton(idle: setup.error == nil ? "Tap card" : "Try again") {
                await setup.runTap()
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Palette.accent)
            Text("Card ready")
                .font(.title2.weight(.bold))

            if let result = setup.result {
                SurfaceCard {
                    VStack(spacing: 12) {
                        InfoRow(label: "Card ID", value: result.cardUid)
                        InfoRow(label: "Wallet ID", value: result.keyUid)
                        InfoRow(label: "Public key", value: Self.short(result.publicKeyHex))
                    }
                }
            }

            Text("Next, this wallet gets a NEAR account, and the agent's approvals appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Continue") {
                if let result = setup.result {
                    model.saveCard(result)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: - Helpers

    private func tapButton(idle: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            if setup.working {
                ProgressView().tint(.white)
            } else {
                Text(idle)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(setup.working)
    }

    private static func short(_ hex: String) -> String {
        guard hex.count > 20 else { return hex }
        return "\(hex.prefix(10))…\(hex.suffix(8))"
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Palette.accent, in: Circle())
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
