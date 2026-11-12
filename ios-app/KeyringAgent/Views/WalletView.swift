import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

private enum WalletAction: String, Identifiable {
    case deposit
    case withdraw
    var id: String { rawValue }
    var title: String { self == .deposit ? "Add to spending" : "Withdraw to account" }
    var icon: String { self == .deposit ? "arrow.down.circle.fill" : "arrow.up.circle.fill" }
}

/// Balances, receive address, and card-signed deposit/withdraw.
struct WalletView: View {
    @EnvironmentObject private var model: AppModel
    @State private var amount = "0.5"
    @State private var pendingAction: WalletAction?
    @State private var showPin = false
    @State private var working = false
    @State private var status: String?
    @State private var error: String?

    private var account: String? { model.card?.accountId }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    BalanceTile(
                        title: "Spending",
                        value: model.context?.balanceNear ?? "—",
                        subtitle: "in the policy"
                    )
                    BalanceTile(
                        title: "Account",
                        value: model.context?.accountBalanceNear ?? "—",
                        subtitle: "for gas"
                    )
                }

                SectionTitle(text: "Move funds")
                SurfaceCard {
                    VStack(spacing: 14) {
                        HStack {
                            TextField("0.5", text: $amount)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("NEAR")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                pendingAction = .deposit
                                showPin = true
                            } label: {
                                Label("Add", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle())

                            Button {
                                pendingAction = .withdraw
                                showPin = true
                            } label: {
                                Label("Withdraw", systemImage: "arrow.up.circle.fill")
                            }
                            .buttonStyle(SecondaryButtonStyle(tint: Palette.accent))
                        }
                        .disabled(working || NearAmount.yocto(amount) == nil)

                        Text("Add moves NEAR from your account into the spending policy. Withdraw moves it back to your account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionTitle(text: "Receive")
                SurfaceCard {
                    VStack(spacing: 14) {
                        if let account {
                            QRCodeView(text: account)
                            Text(account)
                                .font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                            Button("Copy account ID") {
                                UIPasteboard.general.string = account
                            }
                            .font(.subheadline)
                        } else {
                            Text("Link a card first.")
                                .foregroundStyle(.secondary)
                        }
                        Text("Send NEAR to this account from any wallet or exchange. Then add it to your spending balance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if let status {
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
                if let error {
                    ReasonBanner(icon: "xmark.octagon.fill", text: error, tone: Palette.danger)
                }
            }
            .padding(20)
        }
        .background(Palette.canvas)
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPin) {
            PinSheet(decision: .wallet) { pin in
                showPin = false
                guard let action = pendingAction else { return }
                Task { await run(action, pin: pin) }
            }
        }
    }

    private func run(_ action: WalletAction, pin: String) async {
        guard let card = model.card, let account = card.accountId else {
            error = "Link a card first."
            return
        }
        guard let yocto = NearAmount.yocto(amount), yocto != "0" else {
            error = "Enter an amount greater than zero."
            return
        }

        error = nil
        status = nil
        working = true
        defer { working = false }

        do {
            status = "Preparing…"
            let prep = try await model.prepareWallet()
            guard prep.account == account, let nonce = UInt64(prep.nonce) else {
                throw NSError(domain: "KeyringAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "The server returned an unexpected account."])
            }

            let args: Data = action == .deposit
                ? Data("{}".utf8)
                : try JSONSerialization.data(withJSONObject: ["amount": yocto])
            let tx = NearFunctionCallTx(
                signerId: account,
                publicKeyHex: card.publicKeyHex,
                nonce: nonce,
                receiverId: prep.receiverId,
                blockHashHex: prep.blockHashHex,
                methodName: action.rawValue,
                argsJSON: args,
                gasTGas: 30,
                depositYocto: action == .deposit ? yocto : "0"
            )

            status = "Hold your card near the top of the iPhone…"
            let cardPIN = pin
            let signature = try await CardSession.shared.run(
                message: "Hold your Keyring card near the top of the iPhone."
            ) { keyringCard, _ in
                try keyringCard.verifyPin(cardPIN)
                return try keyringCard.sign(path: AppConfig.cardPath, digest: [UInt8](tx.digest()))
            }

            guard let expected = Data(hex: card.publicKeyHex), expected.count == 64,
                  signature.publicKey.count == 65,
                  Array(signature.publicKey.dropFirst()) == [UInt8](expected)
            else {
                throw CardSignerError.keyMismatch
            }

            status = "Broadcasting…"
            let result = try await model.submitWallet(
                unsignedTxBase64: try tx.unsignedBytes().base64EncodedString(),
                signatureHex: Data(signature.signature).hex
            )
            guard result.ok else {
                throw NSError(domain: "KeyringAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: result.failure ?? "The network rejected the transfer."])
            }
            status = action == .deposit ? "Added to your spending balance." : "Sent to your account."
            await model.refresh(silent: true)
        } catch {
            self.error = AppModel.friendly(error)
            status = nil
        }
    }
}

private struct BalanceTile: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.bold))
                Text("NEAR \(subtitle)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = makeImage() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 150)
        }
    }

    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
