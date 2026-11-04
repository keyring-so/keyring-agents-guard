import SwiftUI

enum Decision: String, Identifiable {
    case approve
    case reject

    var id: String { rawValue }
    var tone: Color { self == .approve ? Palette.accent : Palette.danger }
    var icon: String { self == .approve ? "checkmark.shield.fill" : "xmark.shield.fill" }
    var title: String { self == .approve ? "Approve this payment" : "Reject this request" }
}

/// Collects the card PIN before the NFC tap. The PIN stays in this view until it is handed to the signer.
struct PinSheet: View {
    let decision: Decision
    let onConfirm: (String) -> Void

    @State private var pin = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: decision.icon)
                .font(.system(size: 44))
                .foregroundStyle(decision.tone)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(decision.title)
                    .font(.title3.weight(.semibold))
                Text("Enter your card PIN. Then you'll hold the card to the top of your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                PinDots(count: pin.count)
                SecureField("", text: $pin)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .opacity(0.02)
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            Button("Continue to card") {
                onConfirm(pin)
            }
            .buttonStyle(PrimaryButtonStyle(tint: decision.tone))
            .disabled(pin.count != AppConfig.cardPINLength)
        }
        .padding(24)
        .presentationDetents([.medium])
        .onAppear { focused = true }
        .onChange(of: pin) { _, newValue in
            let digits = String(newValue.filter(\.isNumber).prefix(AppConfig.cardPINLength))
            if digits != newValue { pin = digits }
        }
    }
}

struct PinDots: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<AppConfig.cardPINLength, id: \.self) { index in
                Circle()
                    .fill(index < count ? Palette.accent : Color.secondary.opacity(0.25))
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.vertical, 10)
    }
}
