import Foundation

/// Creates the user's NEAR account through the sponsor and has the card sign register + deposit.
/// Nothing secret leaves the phone except the card's public key.
@MainActor
final class OnboardingModel: ObservableObject {
    let card: CardRecord
    private(set) var api: APIClient

    @Published var status: String?
    @Published var error: String?
    @Published var working = false
    @Published var account: String?

    init(card: CardRecord, baseURL: URL) {
        self.card = card
        self.api = APIClient(baseURL: baseURL)
    }

    func setBaseURL(_ url: URL) {
        api = APIClient(baseURL: url)
    }

    func link(pin: String) async {
        guard CardSession.isAvailable else {
            error = "NFC is not available. Use a physical iPhone with NFC enabled."
            return
        }
        guard pin.count == AppConfig.cardPINLength else {
            error = "Enter the 6-digit card PIN."
            return
        }
        guard let hexKey = Data(hex: card.publicKeyHex), hexKey.count == 64 else {
            error = "The card's public key is missing."
            return
        }

        error = nil
        account = nil
        working = true
        defer { working = false }

        do {
            status = "Creating your NEAR account…"
            let prepared = try await api.onboardSponsor(cardPublicKeyHex: card.publicKeyHex)
            guard prepared.account == prepared.signerId,
                  let nonce = UInt64(prepared.nonce)
            else {
                throw Self.failure("The sponsor returned an unexpected account.")
            }

            let registerArgs = try JSONSerialization.data(withJSONObject: [
                "approver_key": prepared.publicKey,
                "agent_key": prepared.agentKey,
                "policy": [
                    "per_tx_max": prepared.policy.per_tx_max,
                    "daily_max": prepared.policy.daily_max,
                    "allowlist": prepared.policy.allowlist,
                ],
            ])
            let registerTx = NearFunctionCallTx(
                signerId: prepared.signerId,
                publicKeyHex: card.publicKeyHex,
                nonce: nonce,
                receiverId: prepared.receiverId,
                blockHashHex: prepared.blockHashHex,
                methodName: "register",
                argsJSON: registerArgs,
                gasTGas: 30,
                depositYocto: prepared.registrationFeeYocto
            )
            let depositTx = NearFunctionCallTx(
                signerId: prepared.signerId,
                publicKeyHex: card.publicKeyHex,
                nonce: nonce + 1,
                receiverId: prepared.receiverId,
                blockHashHex: prepared.blockHashHex,
                methodName: "deposit",
                argsJSON: Data("{}".utf8),
                gasTGas: 30,
                depositYocto: prepared.depositYocto
            )

            status = "Hold your card near the top of iPhone…"
            let cardPIN = pin
            let signatures = try await CardSession.shared.run(
                message: "Hold your Keyring card near the top of the iPhone."
            ) { keyringCard, _ in
                try keyringCard.verifyPin(cardPIN)
                let register = try keyringCard.sign(path: AppConfig.cardPath, digest: [UInt8](registerTx.digest()))
                let deposit = try keyringCard.sign(path: AppConfig.cardPath, digest: [UInt8](depositTx.digest()))
                return [register, deposit]
            }
            guard signatures.count == 2 else {
                throw Self.failure("The card did not return both signatures.")
            }

            for (index, signature) in signatures.enumerated() {
                guard signature.publicKey.count == 65,
                      Array(signature.publicKey.dropFirst()) == [UInt8](hexKey)
                else {
                    throw CardSignerError.keyMismatch
                }
                let tx = index == 0 ? registerTx : depositTx
                status = index == 0 ? "Registering with the hub…" : "Funding your balance…"
                let result = try await api.broadcast(
                    unsignedTxBase64: try tx.unsignedBytes().base64EncodedString(),
                    signatureHex: Data(signature.signature).hex,
                    publicKey: prepared.publicKey
                )
                guard result.ok else {
                    throw Self.failure(result.failure ?? "The network rejected the transaction.")
                }
            }

            account = prepared.account
            status = "Account ready."
        } catch {
            self.error = AppModel.friendly(error)
            status = nil
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KeyringAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
