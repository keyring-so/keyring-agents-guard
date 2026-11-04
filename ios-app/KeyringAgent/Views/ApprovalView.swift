import SwiftUI

struct ApprovalView: View {
    let spend: PendingSpend

    @EnvironmentObject private var model: AppModel
    @State private var decision: Decision?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                ReasonBanner(
                    icon: spend.isHighRisk ? "exclamationmark.shield.fill" : "info.circle.fill",
                    text: reasonSentence(spend.reason, perTxMaxNear: model.context?.policy.perTxMaxNear),
                    tone: spend.isHighRisk ? Palette.danger : Palette.warning
                )

                if !spend.memo.isEmpty {
                    memoCard
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "What the card signs")
                    SurfaceCard {
                        VStack(spacing: 12) {
                            InfoRow(label: "Contract", value: AppConfig.account)
                            InfoRow(label: "Action", value: "Approve or reject request \(spend.id)")
                            InfoRow(label: "Deposit", value: "0 NEAR")
                            InfoRow(label: "Gas", value: "30 TGas")
                        }
                    }
                }

                if case .failed(let message) = model.phase {
                    ReasonBanner(icon: "xmark.octagon.fill", text: message, tone: Palette.danger)
                }
            }
            .padding(20)
        }
        .background(Palette.canvas)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $decision) { choice in
            PinSheet(decision: choice) { pin in
                decision = nil
                Task { await run(choice, pin: pin) }
            }
        }
        .overlay {
            if case .working(let text) = model.phase {
                WorkingOverlay(text: text)
            }
        }
        .onAppear { model.resetPhase() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("Agent wants to pay")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(spend.amountNear) NEAR")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text(spend.receiverId)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.surface, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var memoCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Agent's note", systemImage: "text.quote")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Untrusted")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.warning.opacity(0.15), in: Capsule())
                        .foregroundStyle(Palette.warning)
                }
                Text(spend.memo)
                    .font(.callout)
                Text("Written by the agent, not the contract. Don't rely on it to describe the payment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if case .done(let result) = model.phase {
            ResultFooter(result: result)
        } else {
            HStack(spacing: 12) {
                Button("Reject") { decision = .reject }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Approve") { decision = .approve }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(model.phase.isWorking)
            .padding(20)
            .background(.bar)
        }
    }

    private func run(_ choice: Decision, pin: String) async {
        switch choice {
        case .approve: await model.approve(spend, pin: pin)
        case .reject: await model.reject(spend, pin: pin)
        }
    }
}

private struct ResultFooter: View {
    let result: SubmitResponse

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Label("Confirmed on NEAR testnet", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Palette.accent)
            if let url = URL(string: result.explorer) {
                Link("View transaction", destination: url)
                    .font(.subheadline)
            }
            Button("Back to requests") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.bar)
    }
}

private struct WorkingOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundStyle(Palette.accent)
                ProgressView()
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}
