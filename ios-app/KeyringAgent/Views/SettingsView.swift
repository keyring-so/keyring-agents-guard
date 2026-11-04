import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("API") {
                InfoRow(label: "Base URL", value: AppConfig.apiBaseURL.absoluteString)
                InfoRow(label: "Account", value: AppConfig.account)
                InfoRow(label: "Policy contract", value: AppConfig.account)
            }

            Section("Card") {
                InfoRow(
                    label: "CA public key",
                    value: String(AppConfig.cardCAPublicKeyHex.prefix(18)) + "…"
                )
                InfoRow(label: "Key path", value: "m/44'/397'/0'/0/0")
                InfoRow(label: "Applet AID", value: "F04B455952494E470101")
            }

            Section("Notes") {
                Text("Use a physical iPhone for NFC. The iOS Simulator cannot read the card.")
                Text("On a device, set AppConfig.apiBaseURL to your Mac's LAN address, for example http://192.168.1.20:8787.")
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
    }
}
