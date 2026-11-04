import CommonCrypto
import CryptoKit
import Foundation

/// BIP39 for the wallet phrase: 128-bit entropy → 12 English words, and the seed the card loads.
/// Seed derivation is PBKDF2-HMAC-SHA512 (2048 rounds, NFKD), the same as the Keyring mobile wallet.
enum Bip39 {
    enum Error: Swift.Error {
        case invalidEntropy
        case derivationFailed
    }

    /// 16 bytes of entropy → 12 words (the checksum is the first 4 bits of SHA-256).
    static func mnemonic(entropy: [UInt8]) throws -> [String] {
        guard entropy.count == 16 else { throw Error.invalidEntropy }

        var bits: [Bool] = []
        bits.reserveCapacity(132)
        for byte in entropy {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> shift) & 1 == 1)
            }
        }
        let checksum = Array(SHA256.hash(data: Data(entropy)))
        for index in 0..<4 {
            bits.append((checksum[0] >> (7 - index)) & 1 == 1)
        }

        return stride(from: 0, to: bits.count, by: 11).map { start in
            var index = 0
            for bit in bits[start..<(start + 11)] {
                index = (index << 1) | (bit ? 1 : 0)
            }
            return bip39English[index]
        }
    }

    static func seed(mnemonic words: [String], passphrase: String = "") throws -> [UInt8] {
        let password = Array(words.joined(separator: " ").decomposedStringWithCanonicalMapping.utf8)
        let salt = Array(("mnemonic" + passphrase).decomposedStringWithCanonicalMapping.utf8)

        var seed = [UInt8](repeating: 0, count: 64)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.bindMemory(to: Int8.self).baseAddress, password.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                2048,
                &seed, seed.count
            )
        }
        guard status == kCCSuccess else { throw Error.derivationFailed }
        return seed
    }
}
