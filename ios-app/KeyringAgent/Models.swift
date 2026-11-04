import Foundation

struct Policy: Codable, Equatable {
    let perTxMaxNear: String
    let dailyMaxNear: String
    let allowlist: [String]
}

struct Budget: Codable, Equatable {
    let spentTodayNear: String
    let remainingTodayNear: String
}

struct AccountContext: Codable, Equatable {
    let account: String
    let rpc: String
    let policy: Policy
    let budget: Budget
    let approverKey: String
    let approverKeyHex: String
    let agentKey: String
    let pendingCount: Int
}

struct PendingSpend: Codable, Identifiable, Hashable {
    let id: String
    let receiverId: String
    let amountYocto: String
    let amountNear: String
    let memo: String
    let reason: String
    let requestedAt: UInt64

    var reasonLabel: String {
        switch reason {
        case "OverTxLimit": return "Over per-payment limit"
        case "OverDailyLimit": return "Over daily budget"
        case "NotAllowlisted": return "Receiver not allowlisted"
        default: return reason
        }
    }

    var isHighRisk: Bool { reason == "NotAllowlisted" }
}

/// Routing data only: the app builds the transaction from these fields itself.
struct PrepareResponse: Codable {
    let action: String
    let id: String
    let pending: PendingSpend
    let signerId: String
    let receiverId: String
    let publicKey: String      // "secp256k1:<base58>", must equal the account's approver key
    let nonce: String          // the next nonce for the approver key, as a decimal string
    let blockHashHex: String   // recent block hash, 32 bytes as hex
}

struct SubmitResponse: Codable, Equatable {
    let ok: Bool
    let hash: String
    let explorer: String
    let failure: String?
}

struct PendingResponse: Codable {
    let account: String
    let pending: [PendingSpend]
}
