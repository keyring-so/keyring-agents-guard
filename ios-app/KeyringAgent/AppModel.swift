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
        guard let context else { return .loading }
        return context.approverKeyHex.lowercased() == card.publicKeyHex.lowercased() ? .ready : .needsAccount
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.baseURLKey).flatMap(APIClient.normalize)
        let url = stored ?? AppConfig.apiBaseURL
        apiBaseURL = url
        api = APIClient(baseURL: url)
        if let data = UserDefaults.standard.data(forKey: Self.cardKey) {
            card = try? JSONDecoder().decode(CardRecord.self, from: data)
        }
    }

    func saveCard(_ result: CardSetupResult) {
        let record = CardRecord(cardUid: result.cardUid, keyUid: result.keyUid, publicKeyHex: result.publicKeyHex)
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: Self.cardKey)
        }
        card = record
    }

    /// Forgets the card on this phone only. The card itself is not changed.
    func forgetCard() {
        UserDefaults.standard.removeObject(forKey: Self.cardKey)
        card = nil
    }

    /// Validates, persists, and reconnects. Returns true when the server answers.
    func saveAPIBaseURL(_ raw: String) async -> Bool {
        guard let url = APIClient.normalize(raw) else {
            error = "Enter a full URL such as http://192.168.1.20:8787"
            return false
        }
        UserDefaults.standard.set(url.absoluteString, forKey: Self.baseURLKey)
        apiBaseURL = url
        api = APIClient(baseURL: url)
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
        let id = components?.queryItems?.first(where: { $0.name == "id" })?.value
        let account = components?.queryItems?.first(where: { $0.name == "account" })?.value
        if let account, account != AppConfig.account { return }
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
                  routing.signerId == AppConfig.account,
                  routing.receiverId == AppConfig.account,
                  let nonce = UInt64(routing.nonce)
            else {
                throw Self.failure("The server returned data that does not match this request. Nothing was signed.")
            }

            // The app builds the transaction itself. The server supplied only the nonce and block hash.
            let tx = NearFunctionCallTx(
                signerId: AppConfig.account,
                publicKeyHex: context.approverKeyHex,
                nonce: nonce,
                receiverId: AppConfig.account,
                blockHashHex: routing.blockHashHex,
                methodName: action,
                argsJSON: try NearFunctionCallTx.args(forId: spend.id),
                gasTGas: 30
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
