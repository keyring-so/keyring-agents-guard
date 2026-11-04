import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var context: AccountContext?
    @Published var pending: [PendingSpend] = []
    @Published var path: [PendingSpend] = []
    @Published var error: String?
    @Published var status: String?
    @Published var lastTx: SubmitResponse?
    @Published var loading = false

    @Published private(set) var apiBaseURL: URL
    private var api: APIClient
    private var pollTask: Task<Void, Never>?

    private static let baseURLKey = "apiBaseURL"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.baseURLKey).flatMap(APIClient.normalize)
        let url = stored ?? AppConfig.apiBaseURL
        apiBaseURL = url
        api = APIClient(baseURL: url)
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
        if !silent { loading = true }
        defer { if !silent { loading = false } }
        do {
            async let contextTask = api.context()
            async let pendingTask = api.pending()
            let (ctx, list) = try await (contextTask, pendingTask)
            self.context = ctx
            self.pending = list
            if !silent { self.error = nil }
        } catch {
            if !silent { self.error = error.localizedDescription }
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

    func approve(_ spend: PendingSpend, pin: String) async {
        await sign(action: "approve", spend: spend, pin: pin)
    }

    func reject(_ spend: PendingSpend, pin: String) async {
        await sign(action: "reject", spend: spend, pin: pin)
    }

    private func sign(action: String, spend: PendingSpend, pin: String) async {
        error = nil
        lastTx = nil
        guard CardSigner.isAvailable else {
            error = "NFC is not available. Use a physical iPhone with NFC enabled."
            return
        }
        guard action == "approve" || action == "reject" else { return }
        guard let context else {
            error = "Account details are not loaded yet. Pull to refresh."
            return
        }
        do {
            status = "Preparing \(action)…"
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

            status = "Hold your card near the iPhone…"
            let signature = try await CardSigner.shared.sign(
                digest: [UInt8](digest),
                pin: pin,
                expectedPublicKey: [UInt8](expectedKey)
            )

            status = "Broadcasting…"
            let result = try await api.submit(
                unsignedTxBase64: unsigned.base64EncodedString(),
                signatureHex: Data(signature.signature).hex
            )
            lastTx = result
            status = result.ok ? "Confirmed on testnet." : "Transaction failed."
            await refresh(silent: true)
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KeyringAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
