import CryptoKit
import Foundation

/// A NEAR v0 transaction with one FunctionCall action, borsh-encoded the way nearcore expects.
/// The app builds these bytes from fields it chooses and signs sha256 of them. The API only
/// supplies the nonce and block hash; it never builds or edits the transaction.
struct NearFunctionCallTx {
    let signerId: String
    let publicKeyHex: String   // secp256k1 x‖y, 64 bytes as hex (no 0x04 prefix)
    let nonce: UInt64
    let receiverId: String
    let blockHashHex: String   // 32 bytes as hex
    let methodName: String
    let argsJSON: Data
    let gasTGas: UInt64
    /// Attached deposit in yoctoNEAR, as a decimal string. Approvals use "0"; onboarding uses the fee and funding.
    let depositYocto: String

    enum BuildError: LocalizedError {
        case invalidPublicKey
        case invalidBlockHash
        case invalidArgs

        var errorDescription: String? {
            switch self {
            case .invalidPublicKey: return "The approver key from the server is malformed."
            case .invalidBlockHash: return "The block hash from the server is malformed."
            case .invalidArgs: return "The request id is malformed."
            }
        }
    }

    /// Borsh bytes of the unsigned transaction. The card signs `digest()` of these bytes.
    func unsignedBytes() throws -> Data {
        guard let publicKey = Data(hex: publicKeyHex), publicKey.count == 64 else {
            throw BuildError.invalidPublicKey
        }
        guard let blockHash = Data(hex: blockHashHex), blockHash.count == 32 else {
            throw BuildError.invalidBlockHash
        }

        var out = Data()
        out.appendBorshString(signerId)
        out.append(1)                              // PublicKey::Secp256k1
        out.append(publicKey)
        out.appendUInt64(nonce)
        out.appendBorshString(receiverId)
        out.append(blockHash)
        out.appendUInt32(1)                        // actions: one item
        out.append(2)                              // Action::FunctionCall
        out.appendBorshString(methodName)
        out.appendBorshBytes(argsJSON)
        out.appendUInt64(gasTGas * 1_000_000_000_000)
        out.appendU128Decimal(depositYocto)
        return out
    }

    /// The 32-byte digest the card signs.
    func digest() throws -> Data {
        Data(SHA256.hash(data: try unsignedBytes()))
    }

    /// `approve` or `reject` with `{"id":"<id>"}`. The id must be digits, so the JSON needs no escaping.
    static func args(forId id: String) throws -> Data {
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else {
            throw BuildError.invalidArgs
        }
        return Data("{\"id\":\"\(id)\"}".utf8)
    }
}

/// A NEAR transaction whose single action is `AddKey`: give the agent an ed25519 function-call key
/// limited to `request_spend` on the hub.
struct NearAddKeyTx {
    let signerId: String
    let publicKeyHex: String   // card key, 64 bytes
    let nonce: UInt64
    let receiverId: String     // the user account (self)
    let blockHashHex: String
    let newPublicKeyHex: String // agent ed25519 key, 32 bytes
    let allowanceYocto: String
    let contractId: String
    let methods: [String]

    enum BuildError: LocalizedError {
        case invalidPublicKey
        case invalidBlockHash
        case invalidAgentKey

        var errorDescription: String? {
            switch self {
            case .invalidPublicKey: return "The card's public key is malformed."
            case .invalidBlockHash: return "The block hash is malformed."
            case .invalidAgentKey: return "The agent's public key is malformed."
            }
        }
    }

    func unsignedBytes() throws -> Data {
        guard let publicKey = Data(hex: publicKeyHex), publicKey.count == 64 else {
            throw BuildError.invalidPublicKey
        }
        guard let blockHash = Data(hex: blockHashHex), blockHash.count == 32 else {
            throw BuildError.invalidBlockHash
        }
        guard let newKey = Data(hex: newPublicKeyHex), newKey.count == 32 else {
            throw BuildError.invalidAgentKey
        }

        var out = Data()
        out.appendBorshString(signerId)
        out.append(1)                              // PublicKey::Secp256k1
        out.append(publicKey)
        out.appendUInt64(nonce)
        out.appendBorshString(receiverId)
        out.append(blockHash)
        out.appendUInt32(1)                        // actions: one item
        out.append(5)                              // Action::AddKey
        out.append(0)                              // PublicKey::Ed25519
        out.append(newKey)
        out.appendUInt64(0)                        // access key nonce
        out.append(0)                              // AccessKeyPermission::FunctionCall
        out.append(1)                              // allowance: Some
        out.appendU128Decimal(allowanceYocto)
        out.appendBorshString(contractId)
        out.appendUInt32(UInt32(methods.count))
        for method in methods {
            out.appendBorshString(method)
        }
        return out
    }

    func digest() throws -> Data {
        Data(SHA256.hash(data: try unsignedBytes()))
    }
}

/// Converts a human NEAR amount ("0.5") to a yoctoNEAR decimal string, and back.
enum NearAmount {
    static func yocto(_ near: String) -> String? {
        let trimmed = near.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isNumber) else { return nil }
        let fracRaw = parts.count > 1 ? String(parts[1]) : ""
        guard fracRaw.allSatisfy(\.isNumber) else { return nil }
        let frac = String(fracRaw.prefix(24)).padding(toLength: 24, withPad: "0", startingAt: 0)
        let digits = String(whole) + frac
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }

    /// Formats a yoctoNEAR decimal string as NEAR, e.g. 500000000000000000000000 → 0.5.
    static func near(_ yocto: String) -> String {
        let digits = yocto.filter(\.isNumber)
        guard !digits.isEmpty else { return yocto }
        let padded = String(repeating: "0", count: max(0, 25 - digits.count)) + digits
        let whole = String(padded.dropLast(24))
        var fraction = String(padded.suffix(24))
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendUInt64(_ value: UInt64) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<UInt64>.size))
    }

    mutating func appendBorshString(_ value: String) {
        appendBorshBytes(Data(value.utf8))
    }

    mutating func appendBorshBytes(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }

    /// Borsh u128: 16 bytes, little-endian. Deposits are small enough to fit.
    mutating func appendU128Decimal(_ decimal: String) {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        for scalar in decimal.unicodeScalars {
            guard let digit = UInt64(String(scalar)), digit < 10 else { continue }
            let lo10 = lo.multipliedFullWidth(by: 10)
            let hi10 = hi.multipliedFullWidth(by: 10)
            precondition(hi10.high == 0, "deposit exceeds u128")
            let (hiWithCarry, hiOverflow) = hi10.low.addingReportingOverflow(lo10.high)
            precondition(!hiOverflow, "deposit exceeds u128")
            let (lowWithDigit, lowCarry) = lo10.low.addingReportingOverflow(digit)
            let (finalHi, finalOverflow) = hiWithCarry.addingReportingOverflow(lowCarry ? 1 : 0)
            precondition(!finalOverflow, "deposit exceeds u128")
            lo = lowWithDigit
            hi = finalHi
        }
        var leLo = lo.littleEndian
        var leHi = hi.littleEndian
        append(Data(bytes: &leLo, count: 8))
        append(Data(bytes: &leHi, count: 8))
    }
}
