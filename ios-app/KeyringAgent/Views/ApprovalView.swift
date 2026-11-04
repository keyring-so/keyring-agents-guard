import SwiftUI

struct ApprovalView: View {
    let spend: PendingSpend

    @EnvironmentObject private var model: AppModel
    @State private var pin = ""
    @State private var working = false

    var body: some View {
        List {
            Section("Payment request") {
                HStack {
                    Text("Amount")
                    Spacer()
                    Text("\(spend.amountNear) NEAR").font(.headline)
                }
                InfoRow(label: "To", value: spend.receiverId)
                HStack {
                    Text("Reason")
                    Spacer()
                    ReasonBadge(reason: spend.reason, text: spend.reasonLabel)
                }
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Card will sign") {
                InfoRow(label: "Contract", value: AppConfig.account)
                InfoRow(label: "Call", value: "approve or reject (\(spend.id))")
                InfoRow(label: "Deposit", value: "0 NEAR")
                InfoRow(label: "Gas", value: "30 TGas")
            }

            if !spend.memo.isEmpty {
                Section("Agent-provided memo — untrusted") {
                    Text(spend.memo)
                        .font(.callout)
                        .textSelection(.enabled)
                    Text("This text came from the agent, not from the contract. It may be malicious.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Authorize with the card") {
                if !CardSigner.isAvailable {
                    Label("NFC is not available in the Simulator. Use a physical iPhone.", systemImage: "iphone.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                SecureField("6-digit card PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)

                Button {
                    Task { await run("approve") }
                } label: {
                    Label("Approve with card", systemImage: "checkmark.shield.fill")
                }
                .disabled(!CardSigner.isAvailable || pin.count != AppConfig.cardPINLength || working)

                Button(role: .destructive) {
                    Task { await run("reject") }
                } label: {
                    Label("Reject", systemImage: "xmark.shield")
                }
                .disabled(!CardSigner.isAvailable || pin.count != AppConfig.cardPINLength || working)
            }

            if let status = model.status {
                Section {
                    Text(status).font(.subheadline)
                }
            }

            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            if let tx = model.lastTx {
                Section("Result") {
                    Text(tx.ok ? "Confirmed on testnet" : "Transaction failed")
                        .font(.subheadline.weight(.semibold))
                    if let url = URL(string: tx.explorer) {
                        Link("View on NEAR Blocks", destination: url)
                    }
                }
            }
        }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var explanation: String {
        switch spend.reason {
        case "OverTxLimit":
            return "This payment is larger than the per-payment limit. The contract held it instead of paying automatically."
        case "OverDailyLimit":
            return "This payment would exceed today's agent budget. The contract held it instead of paying automatically."
        case "NotAllowlisted":
            return "The receiver is not on the allowlist. The contract held it instead of paying automatically."
        default:
            return "The contract held this payment for human approval."
        }
    }

    private func run(_ action: String) async {
        working = true
        defer { working = false }
        if action == "approve" {
            await model.approve(spend, pin: pin)
        } else {
            await model.reject(spend, pin: pin)
        }
        if model.error == nil { pin = "" }
    }
}
