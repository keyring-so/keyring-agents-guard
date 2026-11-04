import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var draftURL = ""
    @State private var saving = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        List {
            Section {
                TextField("http://192.168.1.20:8787", text: $draftURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Save and connect")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(saving || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Reset to default") {
                    draftURL = AppConfig.apiBaseURL.absoluteString
                    Task { await save() }
                }
                .disabled(saving)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(messageIsError ? .red : .green)
                }
            } header: {
                Text("API server")
            } footer: {
                Text("Simulator: http://127.0.0.1:8787. iPhone: your Mac's LAN address, with `node api/server.mjs` running on the Mac.")
            }

            Section("Account") {
                InfoRow(label: "Account", value: AppConfig.account)
                InfoRow(label: "Connected to", value: model.apiBaseURL.absoluteString)
            }

            Section {
                if let card = model.card {
                    InfoRow(label: "Card ID", value: card.cardUid)
                }
                Button("Forget card on this phone", role: .destructive) {
                    model.forgetCard()
                }
            } header: {
                Text("Card")
            } footer: {
                Text("Forgetting only removes the card from this phone. The card and its wallet are not changed.")
            }

            Section("Card reader") {
                InfoRow(
                    label: "CA public key",
                    value: String(AppConfig.cardCAPublicKeyHex.prefix(18)) + "…"
                )
                InfoRow(label: "Key path", value: "m/44'/397'/0'/0/0")
                InfoRow(label: "Applet AID", value: "F04B455952494E470101")
            }

            Section("Notes") {
                Text("Use a physical iPhone for NFC. The iOS Simulator cannot read the card.")
                Text("The API builds the unsigned approve/reject transaction; the card signs its hash. The API never sees the card key or the PIN.")
            }

            if let context = model.context {
                Section("On-chain") {
                    InfoRow(label: "Approver key", value: context.approverKey)
                    InfoRow(label: "Agent key", value: context.agentKey)
                    InfoRow(label: "Per-payment cap", value: "\(context.policy.perTxMaxNear) NEAR")
                    InfoRow(label: "Daily budget", value: "\(context.policy.dailyMaxNear) NEAR")
                    InfoRow(
                        label: "Allowlist",
                        value: context.policy.allowlist.isEmpty
                            ? "any receiver"
                            : context.policy.allowlist.joined(separator: ", ")
                    )
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draftURL = model.apiBaseURL.absoluteString }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let ok = await model.saveAPIBaseURL(draftURL)
        messageIsError = !ok
        if ok {
            draftURL = model.apiBaseURL.absoluteString
            message = "Connected. Saved for next launch."
        } else {
            message = model.error ?? "Could not connect."
        }
    }
}
