import Foundation

/// One signing attempt, from preparing the transaction to the network's answer.
enum SigningPhase: Equatable {
    case idle
    case working(String)
    case done(SubmitResponse)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var context: AccountContext?
    @Published var pending: [PendingSpend] = []
    @Published var path: [PendingSpend] = []
    @Published var error: String?
    @Published var phase: SigningPhase = .idle
    @Published var pairing: Pairing?
    /// True when a `keyring-agent://pair?code=…` link opened the app while it was ready.
    @Published var pairRequested = false
    @Published private(set) var card: CardRecord?

    @Published private(set) var apiBaseURL: URL
    private var api: APIClient
    private var pollTask: Task<Void, Never>?

    private static let baseURLKey = "apiBaseURL"
    private static let cardKey = "cardRecord"

    /// Where the phone is in first-run setup. Approvals appear only at `.ready`.
    enum Stage: Equatable {
        case loading
        case needsCard
        case needsAccount
        case ready
    }

    var stage: Stage {
        guard let card else { return .needsCard }
        guard let account = card.accountId else { return .needsAccount }
        guard let context else {
            // A failed load before the account is linked still shows the card and its key.
            return error == nil ? .loading : .needsAccount
        }
        return context.account == account
            && context.approverKeyHex.lowercased() == card.publicKeyHex.lowercased()
            ? .ready : .needsAccount
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.baseURLKey).flatMap(APIClient.normalize)
        let url = stored ?? AppConfig.apiBaseURL
        apiBaseURL = url
        var loadedCard: CardRecord?
        if let data = UserDefaults.standard.data(forKey: Self.cardKey) {
            loadedCard = try? JSONDecoder().decode(CardRecord.self, from: data)
        }
        card = loadedCard
        api = APIClient(baseURL: url, account: loadedCard?.accountId)
    }

    func saveCard(_ result: CardSetupResult) {
        let record = CardRecord(
            cardUid: result.cardUid,
            keyUid: result.keyUid,
            publicKeyHex: result.publicKeyHex,
            accountId: nil
        )
        persist(record)
        card = record
        api = APIClient(baseURL: apiBaseURL, account: nil)
    }

    /// Called after the sponsor creates the account and the card signs register + deposit.
    func saveAccount(_ account: String) {
        guard var record = card else { return }
        record.accountId = account
        persist(record)
        card = record
        api = APIClient(baseURL: apiBaseURL, account: account)
        Task { await refresh() }
    }

    private func persist(_ record: CardRecord) {
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: Self.cardKey)
        }
    }

    /// Forgets the card on this phone only. The card itself is not changed.
    func forgetCard() {
        UserDefaults.standard.removeObject(forKey: Self.cardKey)
        card = nil
    }

    /// Saves the server without probing it (used during onboarding, before an account exists).
    @discardableResult
    func setAPIBaseURL(_ raw: String) -> Bool {
        guard let url = APIClient.normalize(raw) else {
            error = "Enter a full URL such as http://192.168.1.20:8787"
            return false
        }
        UserDefaults.standard.set(url.absoluteString, forKey: Self.baseURLKey)
        apiBaseURL = url
        api = APIClient(baseURL: url, account: card?.accountId)
        return true
    }

    /// Validates, persists, and reconnects. Returns true when the server answers.
    func saveAPIBaseURL(_ raw: String) async -> Bool {
        guard let url = APIClient.normalize(raw) else {
            error = "Enter a full URL such as http://192.168.1.20:8787"
            return false
        }
        UserDefaults.standard.set(url.absoluteString, forKey: Self.baseURLKey)
        apiBaseURL = url
        api = APIClient(baseURL: url, account: card?.accountId)
        error = nil
        await refresh()
        return error == nil
    }

    func refresh(silent: Bool = false) async {
        do {
            async let contextTask = api.context()
            async let pendingTask = api.pending()
            let (ctx, list) = try await (contextTask, pendingTask)
            self.context = ctx
            self.pending = list
            if !silent { self.error = nil }
        } catch {
            if !silent { self.error = Self.friendly(error) }
        }
    }

    /// Cheap poll: only the pending list. The account context changes rarely, so it is not polled.
    func refreshPending() async {
        do {
            pending = try await api.pending()
        } catch {
            // Keep the last list on screen; a manual refresh shows the error.
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPending()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Handle keyring-agent://approve?account=…&id=… (and the future universal link).
    func handle(url: URL) {
        guard url.scheme == AppConfig.urlScheme || url.scheme == "https" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if url.host == "pair" {
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                Task {
                    await loadPairing(code)
                    if pairing != nil { pairRequested = true }
                }
            }
            return
        }

        let id = components?.queryItems?.first(where: { $0.name == "id" })?.value
        let account = components?.queryItems?.first(where: { $0.name == "account" })?.value
        if let account, account != (card?.accountId ?? AppConfig.account) { return }
        guard let id else { return }

        if let spend = pending.first(where: { $0.id == id }) {
            path = [spend]
        } else {
            Task {
                await refresh()
                if let spend = pending.first(where: { $0.id == id }) {
                    path = [spend]
                }
            }
        }
    }

    func resetPhase() {
        guard !phase.isWorking else { return }
        phase = .idle
    }

    func loadPairing(_ code: String) async {
        do {
            pairing = try await api.fetchPair(code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            error = nil
        } catch {
            self.error = AppModel.friendly(error)
        }
    }

    func completePair(_ account: String) async throws {
        guard let code = pairing?.code else { return }
        var lastError: Error?
        for _ in 0..<3 {
            do {
                pairing = try await api.completePair(code: code, account: account)
                return
            } catch let error as APIError {
                // 409 means the agent key is not on the account yet; retrying will not help.
                if case .http(409, _) = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw lastError ?? Self.failure("Pairing did not complete.")
    }

    func pairStatus(_ account: String) async throws -> PairStatus {
        guard let code = pairing?.code else {
            throw Self.failure("Load a pairing code first.")
        }
        return try await api.pairStatus(code: code, account: account)
    }

    /// Nonce, block hash, and approver key for a card-signed wallet action.
    func prepareWallet() async throws -> OnboardPrepare {
        guard let card, let account = card.accountId else {
            throw Self.failure("The card is not linked to an account yet.")
        }
        return try await api.prepareOnboarding(account: account, cardPublicKeyHex: card.publicKeyHex)
    }

    /// Relay a card-signed deposit/withdraw transaction.
    func submitWallet(unsignedTxBase64: String, signatureHex: String) async throws -> SubmitResponse {
        try await api.submit(unsignedTxBase64: unsignedTxBase64, signatureHex: signatureHex)
    }

    func approve(_ spend: PendingSpend, pin: String) async {
        await sign(action: "approve", spend: spend, pin: pin)
    }

    func reject(_ spend: PendingSpend, pin: String) async {
        await sign(action: "reject", spend: spend, pin: pin)
    }

    private func sign(action: String, spend: PendingSpend, pin: String) async {
        guard action == "approve" || action == "reject" else { return }
        guard CardSigner.isAvailable else {
            phase = .failed("NFC is not available. Use a physical iPhone with NFC enabled.")
            return
        }
        guard let context else {
            phase = .failed("Account details are not loaded yet. Pull to refresh and try again.")
            return
        }

        do {
            phase = .working("Preparing")
            let routing = try await api.prepare(action: action, id: spend.id)

            // Routing data must agree with what the human is looking at and with the account.
            guard routing.pending.id == spend.id,
                  routing.pending.receiverId == spend.receiverId,
                  routing.pending.amountYocto == spend.amountYocto,
                  routing.publicKey == context.approverKey,
                  routing.signerId == context.account,
                  routing.receiverId == context.contractId,
                  let nonce = UInt64(routing.nonce)
            else {
                throw Self.failure("The server returned data that does not match this request. Nothing was signed.")
            }

            // The app builds the transaction itself. The server supplied only the nonce and block hash.
            let tx = NearFunctionCallTx(
                signerId: context.account,
                publicKeyHex: context.approverKeyHex,
                nonce: nonce,
                receiverId: context.contractId,
                blockHashHex: routing.blockHashHex,
                methodName: action,
                argsJSON: try NearFunctionCallTx.args(forId: spend.id),
                gasTGas: 30,
                depositYocto: "0"
            )
            let unsigned = try tx.unsignedBytes()
            let digest = try tx.digest()
            guard let expectedKey = Data(hex: context.approverKeyHex), expectedKey.count == 64 else {
                throw Self.failure("The approver key is malformed. Nothing was signed.")
            }

            phase = .working("Hold your card near the top of iPhone")
            let signature = try await CardSigner.shared.sign(
                digest: [UInt8](digest),
                pin: pin,
                expectedPublicKey: [UInt8](expectedKey)
            )

            phase = .working("Broadcasting")
            let result = try await api.submit(
                unsignedTxBase64: unsigned.base64EncodedString(),
                signatureHex: Data(signature.signature).hex
            )
            phase = result.ok ? .done(result) : .failed(result.failure ?? "The network rejected the transaction.")
            await refresh(silent: true)
        } catch {
            phase = .failed(Self.friendly(error))
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KeyringAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Plain-language messages. Raw RPC and JSON text stays out of the UI.
    static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("-429") || text.localizedCaseInsensitiveContains("rate limit") {
            return "The network is busy. Try again in a moment."
        }
        if text.localizedCaseInsensitiveContains("could not connect")
            || text.localizedCaseInsensitiveContains("offline")
            || text.localizedCaseInsensitiveContains("timed out") {
            return "Can't reach the Keyring API. Check the server address in Settings."
        }
        if text.hasPrefix("API ") {
            return "The Keyring API returned an error. Check Settings and try again."
        }
        return text
    }
}
