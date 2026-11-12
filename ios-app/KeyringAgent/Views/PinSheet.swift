import SwiftUI

enum Decision: String, Identifiable {
    case approve
    case reject
    case onboard
    case wallet
    case pair

    var id: String { rawValue }
    var tone: Color { self == .reject ? Palette.danger : Palette.accent }
    var icon: String {
        switch self {
        case .approve: return "checkmark.shield.fill"
        case .reject: return "xmark.shield.fill"
        case .onboard: return "creditcard.fill"
        case .wallet: return "arrow.left.arrow.right"
        case .pair: return "link"
        }
    }
    var title: String {
        switch self {
        case .approve: return "Approve this payment"
        case .reject: return "Reject this request"
        case .onboard: return "Authorize setup"
        case .wallet: return "Authorize wallet transfer"
        case .pair: return "Authorize this agent"
        }
    }
}

/// Collects the card PIN before the NFC tap. The PIN stays in this view until it is handed to the signer.
struct PinSheet: View {
    let decision: Decision
    let onConfirm: (String) -> Void

    @State private var pin = ""

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

            PinField(pin: $pin)

            Button("Continue to card") {
                onConfirm(pin)
            }
            .buttonStyle(PrimaryButtonStyle(tint: decision.tone))
            .disabled(pin.count != AppConfig.cardPINLength)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

/// Six-digit entry shown as dots. Digits only; the field keeps keyboard focus.
struct PinField: View {
    @Binding var pin: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            PinDots(count: pin.count)
            SecureField("", text: $pin)
                .keyboardType(.numberPad)
                .focused($focused)
                .opacity(0.02)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
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
