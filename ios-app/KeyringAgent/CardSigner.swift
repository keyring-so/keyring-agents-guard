import Foundation

struct CardSignature {
    let publicKey: [UInt8]   // 65 bytes, uncompressed
    let signature: [UInt8]   // 64 bytes, r‖s low-s
}

enum CardSignerError: LocalizedError {
    case nfcUnavailable
    case cancelled
    case timeout
    case card(String)
    case keyMismatch

    var errorDescription: String? {
        switch self {
        case .nfcUnavailable:
            return "NFC is not available. Use a physical iPhone with NFC enabled."
        case .cancelled:
            return "Card tap cancelled."
        case .timeout:
            return "The card did not respond in time."
        case let .card(message):
            return message
        case .keyMismatch:
            return "This card does not match the account's approver key."
        }
    }
}

/// One NFC tap to sign a 32-byte digest: PIN check, then SIGN. The PIN stays on the phone
/// until it is sent to the card over the NFC secure channel.
final class CardSigner {
    static let shared = CardSigner()
    static var isAvailable: Bool { CardSession.isAvailable }

    func sign(digest: [UInt8], pin: String, expectedPublicKey: [UInt8]?) async throws -> CardSignature {
        guard digest.count == 32 else {
            throw CardSignerError.card("The transaction hash must be 32 bytes.")
        }
        guard pin.count == AppConfig.cardPINLength else {
            throw CardSignerError.card("Enter the \(AppConfig.cardPINLength)-digit card PIN.")
        }

        return try await CardSession.shared.run(message: "Hold your Keyring card near the top of the iPhone.") { card, _ in
            try card.verifyPin(pin)
            let (publicKey, signature) = try card.sign(path: AppConfig.cardPath, digest: digest)

            if let expectedPublicKey, publicKey.count == 65 {
                guard Array(publicKey.dropFirst()) == expectedPublicKey else {
                    throw CardSignerError.keyMismatch
                }
            }
            return CardSignature(publicKey: publicKey, signature: signature)
        }
    }
}
