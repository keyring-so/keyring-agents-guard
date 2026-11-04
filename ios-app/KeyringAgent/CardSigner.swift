import CoreNFC
import Foundation
import KeyringCardClient

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

/// One NFC tap: SELECT → secure channel → VERIFY PIN → SIGN(hash).
/// The PIN stays on the phone and is only sent to the card over the NFC link.
final class CardSigner: NSObject, @unchecked Sendable {
    static let shared = CardSigner()
    static var isAvailable: Bool { NFCReaderSession.readingAvailable }

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<CardSignature, Error>?
    private var pin = ""
    private var digest: [UInt8] = []
    private var expectedPublicKey: [UInt8]?
    private var didResume = false

    func sign(digest: [UInt8], pin: String, expectedPublicKey: [UInt8]?) async throws -> CardSignature {
        guard NFCReaderSession.readingAvailable else { throw CardSignerError.nfcUnavailable }
        guard digest.count == 32 else {
            throw CardSignerError.card("The transaction hash must be 32 bytes.")
        }
        guard pin.count == AppConfig.cardPINLength else {
            throw CardSignerError.card("Enter the \(AppConfig.cardPINLength)-digit card PIN.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
                    continuation.resume(throwing: CardSignerError.card("Could not start the NFC session."))
                    return
                }

                self.continuation = continuation
                self.pin = pin
                self.digest = digest
                self.expectedPublicKey = expectedPublicKey
                self.didResume = false
                self.session = session

                session.alertMessage = "Hold your Keyring card near the top of the iPhone."
                session.begin()
            }
        }
    }

    private func finish(
        _ result: Result<CardSignature, Error>,
        session: NFCTagReaderSession,
        message: String? = nil
    ) {
        DispatchQueue.main.async {
            guard !self.didResume else { return }
            self.didResume = true
            if let message { session.alertMessage = message }
            session.invalidate()
            self.session = nil
            self.continuation?.resume(with: result)
            self.continuation = nil
            self.pin = ""
            self.digest = []
            self.expectedPublicKey = nil
        }
    }
}

extension CardSigner: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async {
            guard !self.didResume else { return }
            let nsError = error as NSError
            if nsError.code == NFCReaderError.readerSessionInvalidationErrorUserCanceled.rawValue {
                self.finish(.failure(CardSignerError.cancelled), session: session)
            } else {
                self.finish(.failure(error), session: session)
            }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first, case let .iso7816(tag) = first else {
            session.invalidate(errorMessage: "That is not a Keyring card.")
            return
        }

        session.connect(to: first) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error), session: session, message: error.localizedDescription)
                return
            }

            // Copy the flow inputs before leaving the main actor.
            let pin = self.pin
            let digest = self.digest
            let expected = self.expectedPublicKey
            let transport = NFCCardTransport(tag: tag)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let ca = Data(hex: AppConfig.cardCAPublicKeyHex), ca.count == 65 else {
                        throw CardSignerError.card("The pinned CA public key is invalid.")
                    }
                    let card = KeyringCard(transport: transport, caPublicKey: [UInt8](ca))
                    _ = try card.selectApplet()
                    try card.openSecureChannel()
                    try card.verifyPin(pin)
                    let (publicKey, signature) = try card.sign(path: AppConfig.cardPath, digest: digest)

                    if let expected, publicKey.count == 65 {
                        guard Array(publicKey.dropFirst()) == expected else {
                            throw CardSignerError.keyMismatch
                        }
                    }

                    self.finish(
                        .success(CardSignature(publicKey: publicKey, signature: signature)),
                        session: session,
                        message: "Signed."
                    )
                } catch {
                    self.finish(.failure(error), session: session, message: "Could not sign.")
                }
            }
        }
    }
}
