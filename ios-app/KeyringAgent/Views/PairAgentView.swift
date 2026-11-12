import SwiftUI

/// Pairs an MCP agent with the existing card account:
/// 1. AddKey(agent, request_spend-only) on the user account
/// 2. set_agent_key(agent) on the hub
/// 3. complete the pairing session so the CLI can pick up the account.
struct PairAgentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var showPin = false
    @State private var working = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Palette.accent)
                Text("Pair an agent")
                    .font(.title2.weight(.bold))
                Text("Run `npx keyring-agent-skills init`, then enter the pairing code. The card authorizes the agent key; the agent never gets the card key.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SurfaceCard {
                    HStack {
                        TextField("Pairing code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Load") {
                            Task {
                                await model.loadPairing(code)
                                if let pairing = model.pairing { code = pairing.code }
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }

                if let pairing = model.pairing {
                    SectionTitle(text: "Agent request")
                    SurfaceCard {
                        VStack(spacing: 12) {
                            InfoRow(label: "Agent key", value: pairing.agentPublicKey)
                            InfoRow(label: "Permission", value: "request_spend only")
                            InfoRow(label: "Policy", value: policyText(pairing))
                            if pairing.paired {
                                InfoRow(label: "Paired to", value: pairing.account ?? "this account")
                            }
                        }
                    }

                    if !pairing.paired {
                        Button {
                            showPin = true
                        } label: {
                            if working {
                                ProgressView().tint(.white)
                            } else {
                                Text("Approve agent with card")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working || !CardSession.isAvailable)
                    }
                }

                if !CardSession.isAvailable {
                    ReasonBanner(
                        icon: "iphone.slash",
                        text: "NFC is not available in the Simulator. Use a physical iPhone.",
                        tone: Palette.warning
                    )
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
        .navigationTitle("Pair agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.pairRequested {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.pairRequested = false
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showPin) {
            PinSheet(decision: .pair) { pin in
                showPin = false
                Task { await run(pin) }
            }
        }
    }

    private func policyText(_ pairing: Pairing) -> String {
        // For an existing account show the policy that is actually on-chain.
        if let policy = model.context?.policy {
            return "\(policy.perTxMaxNear) NEAR per payment, \(policy.dailyMaxNear) NEAR daily"
        }
        return "\(NearAmount.near(pairing.policy.per_tx_max)) NEAR per payment, \(NearAmount.near(pairing.policy.daily_max)) NEAR daily"
    }

    /// One card-signed transaction ready to relay.
    private struct PendingTx {
        let label: String
        let unsigned: Data
        let digest: Data
    }

    private func run(_ pin: String) async {
        guard let card = model.card, let account = card.accountId, let pairing = model.pairing else {
            error = "Link a card and load a pairing code first."
            return
        }
        guard !pairing.paired else { return }

        error = nil
        status = nil
        working = true
        defer { working = false }

        do {
            // A pairing can be half done (account key added, hub not set, or the reverse).
            // Sign only what is missing.
            status = "Checking the pairing…"
            let info = try await model.pairStatus(account)
            if info.ready {
                try await model.completePair(account)
                status = "Agent paired."
                await model.refresh(silent: true)
                return
            }

            status = "Preparing…"
            let prep = try await model.prepareWallet()
            guard prep.account == account, let nonce = UInt64(prep.nonce) else {
                throw NSError(domain: "KeyringAgent", code: 5, userInfo: [NSLocalizedDescriptionKey: "The server returned an unexpected account."])
            }

            var txs: [PendingTx] = []
            var nextNonce = nonce
            if !info.accountKey {
                let tx = NearAddKeyTx(
                    signerId: account,
                    publicKeyHex: card.publicKeyHex,
                    nonce: nextNonce,
                    receiverId: account,
                    blockHashHex: prep.blockHashHex,
                    newPublicKeyHex: pairing.agentKeyHex,
                    allowanceYocto: "250000000000000000000000", // 0.25 NEAR for agent gas
                    contractId: prep.receiverId,
                    methods: ["request_spend"]
                )
                txs.append(PendingTx(
                    label: "Adding the agent key to your account…",
                    unsigned: try tx.unsignedBytes(),
                    digest: try tx.digest()
                ))
                nextNonce += 1
            }
            if !info.agentKey {
                let args = try JSONSerialization.data(withJSONObject: ["agent_key": pairing.agentPublicKey])
                let tx = NearFunctionCallTx(
                    signerId: account,
                    publicKeyHex: card.publicKeyHex,
                    nonce: nextNonce,
                    receiverId: prep.receiverId,
                    blockHashHex: prep.blockHashHex,
                    methodName: "set_agent_key",
                    argsJSON: args,
                    gasTGas: 30,
                    depositYocto: "0"
                )
                txs.append(PendingTx(
                    label: "Authorizing the agent on the hub…",
                    unsigned: try tx.unsignedBytes(),
                    digest: try tx.digest()
                ))
            }
            guard !txs.isEmpty else {
                throw NSError(domain: "KeyringAgent", code: 6, userInfo: [NSLocalizedDescriptionKey: "There is nothing left to authorize."])
            }

            status = "Hold your card near the top of the iPhone…"
            let cardPIN = pin
            let signatures = try await CardSession.shared.run(
                message: "Hold your Keyring card near the top of the iPhone."
            ) { keyringCard, _ in
                try keyringCard.verifyPin(cardPIN)
                return try txs.map { tx in
                    try keyringCard.sign(path: AppConfig.cardPath, digest: [UInt8](tx.digest))
                }
            }

            guard let expected = Data(hex: card.publicKeyHex), expected.count == 64,
                  signatures.count == txs.count
            else {
                throw NSError(domain: "KeyringAgent", code: 7, userInfo: [NSLocalizedDescriptionKey: "The card did not return every signature."])
            }
            for signature in signatures {
                guard signature.publicKey.count == 65,
                      Array(signature.publicKey.dropFirst()) == [UInt8](expected)
                else {
                    throw CardSignerError.keyMismatch
                }
            }

            for (index, tx) in txs.enumerated() {
                status = tx.label
                let result = try await model.submitWallet(
                    unsignedTxBase64: tx.unsigned.base64EncodedString(),
                    signatureHex: Data(signatures[index].signature).hex
                )
                guard result.ok else {
                    throw NSError(
                        domain: "KeyringAgent",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: result.failure ?? "The network rejected the transaction."]
                    )
                }
            }

            try await model.completePair(account)
            status = "Agent paired."
            await model.refresh(silent: true)
        } catch {
            self.error = AppModel.friendly(error)
            status = nil
        }
    }
}
