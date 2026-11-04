import Foundation
import KeyringCardClient
import Security

struct CardSetupResult: Equatable {
    let cardUid: String
    let keyUid: String
    /// 64-byte secp256k1 x‖y at AppConfig.cardPath, as hex. This is the wallet's approver key.
    let publicKeyHex: String
}

enum CardSetupError: LocalizedError {
    case alreadyHasWallet

    var errorDescription: String? {
        switch self {
        case .alreadyHasWallet:
            return "This card already has a wallet. Factory reset the card before setting it up again."
        }
    }
}

/// Phone-side wallet setup. The PIN and the 12 words stay on the phone until the single card tap:
/// that tap sets the PIN (if none), verifies it, loads the seed, and reads the wallet's public key.
@MainActor
final class CardSetupModel: ObservableObject {
    enum Step: Equatable {
        case intro, check, pin, words, tap, done
    }

    @Published var step: Step = .intro
    @Published var pin = ""
    @Published var wroteDown = false
    @Published var words: [String] = []
    @Published var result: CardSetupResult?
    @Published var error: String?
    @Published var working = false

    private var firstPin: String?
    private var chosenPin = ""
    private var seed: [UInt8] = []

    var pinPrompt: String {
        firstPin == nil ? "Choose a 6-digit PIN" : "Enter the PIN again"
    }

    /// First entry stores the PIN; the confirmation must match it. Mismatches start over.
    func submitPin() {
        error = nil
        if let firstPin {
            guard pin == firstPin else {
                error = "The PINs don't match. Start again."
                self.firstPin = nil
                pin = ""
                return
            }
            chosenPin = pin
            pin = ""
            self.firstPin = nil
            generateWords()
            step = .words
        } else {
            firstPin = pin
            pin = ""
        }
    }

    /// First tap: confirms this is a Keyring card (certificate checked against the pinned CA)
    /// and that it has no wallet yet. Nothing is written to the card.
    func checkCard() async {
        guard CardSession.isAvailable else {
            error = CardSignerError.nfcUnavailable.localizedDescription
            return
        }
        error = nil
        working = true
        defer { working = false }

        do {
            let info = try await CardSession.shared.run(message: "Hold your Keyring card near the top of the iPhone.") {
                (_: KeyringCard, info: CardInfo) throws -> CardInfo in info
            }
            guard !info.seedLoaded else {
                error = CardSetupError.alreadyHasWallet.localizedDescription
                return
            }
            step = .pin
        } catch {
            self.error = Self.friendly(error)
        }
    }

    func runTap() async {
        guard CardSession.isAvailable else {
            error = CardSignerError.nfcUnavailable.localizedDescription
            return
        }
        error = nil
        working = true
        defer { working = false }

        let pin = chosenPin
        let seed = self.seed
        do {
            let setup = try await CardSession.shared.run(message: "Hold your Keyring card near the top of the iPhone.") {
                (card: KeyringCard, info: CardInfo) throws -> CardSetupResult in
                guard !info.seedLoaded else { throw CardSetupError.alreadyHasWallet }
                if !info.pinSet {
                    try card.setPin(pin)
                }
                try card.verifyPin(pin)
                let keyUid = try card.loadSeed(seed)
                let publicKey = try card.exportPublicKey(path: AppConfig.cardPath)
                return CardSetupResult(
                    cardUid: Data(info.cardUid).hex,
                    keyUid: Data(keyUid).hex,
                    publicKeyHex: Data(publicKey.dropFirst()).hex
                )
            }
            result = setup
            clearSecrets()
            step = .done
        } catch {
            self.error = Self.friendly(error)
        }
    }

    func restart() {
        clearSecrets()
        firstPin = nil
        pin = ""
        wroteDown = false
        error = nil
        result = nil
        step = .intro
    }

    private func generateWords() {
        var entropy = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy)
        do {
            guard status == errSecSuccess else { throw Bip39.Error.invalidEntropy }
            words = try Bip39.mnemonic(entropy: entropy)
            seed = try Bip39.seed(mnemonic: words)
            wroteDown = false
        } catch {
            self.error = "Could not create the recovery words. Try again."
            step = .intro
        }
    }

    private func clearSecrets() {
        words = []
        seed = []
        chosenPin = ""
    }

    private static func friendly(_ error: Error) -> String {
        if let setupError = error as? CardSetupError {
            return setupError.localizedDescription
        }
        if let status = error as? CardStatusError {
            if status.sw & 0xFFF0 == 0x63C0 {
                return "Wrong PIN. \(status.sw & 0x0F) tries left before the card locks."
            }
            if status.sw == 0x6983 {
                return "The card is locked after too many wrong PINs. It needs a factory reset."
            }
            if status.sw == 0x6985 {
                return "The card is not ready for setup. Check that the card certificate is stored."
            }
        }
        return error.localizedDescription
    }
}
