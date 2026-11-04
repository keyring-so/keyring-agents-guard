import CoreNFC
import Foundation
import KeyringCardClient

/// One NFC tap: SELECT, open the secure channel (the card certificate is checked against the
/// pinned CA), then run the caller's card commands while the card is held. Runs are single-flight.
final class CardSession: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {
    static let shared = CardSession()
    static var isAvailable: Bool { NFCReaderSession.readingAvailable }

    private var session: NFCTagReaderSession?
    private var work: ((KeyringCard, CardInfo) throws -> Any)?
    private var completion: ((Result<Any, Error>) -> Void)?
    private var finished = false

    func run<T>(message: String, _ body: @escaping (KeyringCard, CardInfo) throws -> T) async throws -> T {
        guard Self.isAvailable else { throw CardSignerError.nfcUnavailable }

        let value: Any = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
                    continuation.resume(throwing: CardSignerError.card("Could not start the NFC session."))
                    return
                }
                self.work = { card, info in try body(card, info) }
                self.completion = { continuation.resume(with: $0) }
                self.finished = false
                self.session = session
                session.alertMessage = message
                session.begin()
            }
        }

        guard let typed = value as? T else {
            throw CardSignerError.card("The card returned an unexpected response.")
        }
        return typed
    }

    private func finish(_ result: Result<Any, Error>, session: NFCTagReaderSession, message: String?) {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            if let message { session.alertMessage = message }
            session.invalidate()
            self.session = nil
            self.work = nil
            let completion = self.completion
            self.completion = nil
            completion?(result)
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let nsError = error as NSError
        let mapped: Error = nsError.code == NFCReaderError.readerSessionInvalidationErrorUserCanceled.rawValue
            ? CardSignerError.cancelled
            : error
        finish(.failure(mapped), session: session, message: nil)
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

            let work = self.work
            let transport = NFCCardTransport(tag: tag)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let work else { throw CardSignerError.card("No card operation was queued.") }
                    guard let ca = Data(hex: AppConfig.cardCAPublicKeyHex), ca.count == 65 else {
                        throw CardSignerError.card("The pinned CA public key is invalid.")
                    }

                    let card = KeyringCard(transport: transport, caPublicKey: [UInt8](ca))
                    let info = try card.selectApplet()
                    try card.openSecureChannel()
                    let value = try work(card, info)

                    self.finish(.success(value), session: session, message: nil)
                } catch {
                    self.finish(.failure(error), session: session, message: "Could not complete the card operation.")
                }
            }
        }
    }
}
