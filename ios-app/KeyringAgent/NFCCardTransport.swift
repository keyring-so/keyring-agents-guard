import CoreNFC
import Foundation
import KeyringCardClient

/// Bridges the synchronous `CardTransport` protocol to CoreNFC's async APDU command.
/// The card flow runs on a background thread; this method blocks that thread, not the UI.
final class NFCCardTransport: CardTransport {
    private let tag: NFCISO7816Tag

    init(tag: NFCISO7816Tag) {
        self.tag = tag
    }

    func transmit(_ command: CommandApdu) throws -> ResponseApdu {
        guard let apdu = NFCISO7816APDU(data: Data(command.toBytes())) else {
            throw CardSignerError.card("Could not encode the APDU.")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var response: ResponseApdu?
        var failure: Error?

        tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
            if let error {
                failure = error
            } else {
                response = ResponseApdu(raw: [UInt8](data) + [sw1, sw2])
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw CardSignerError.timeout
        }
        if let failure { throw failure }
        guard let response else { throw CardSignerError.card("The card returned no response.") }
        return response
    }
}
