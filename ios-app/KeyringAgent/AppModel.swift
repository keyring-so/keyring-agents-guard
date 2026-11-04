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
        do {
            status = "Preparing \(action)…"
            let prepared = try await api.prepare(action: action, id: spend.id)

            // The server must return the same intent the human is looking at.
            guard prepared.pending.id == spend.id,
                  prepared.pending.receiverId == spend.receiverId,
                  prepared.pending.amountYocto == spend.amountYocto else {
                throw NSError(
                    domain: "KeyringAgent",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The server returned a different request. Aborted."]
                )
            }

            guard let hash = Data(hex: prepared.hashHex), hash.count == 32 else {
                throw NSError(
                    domain: "KeyringAgent",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The server returned an invalid transaction hash."]
                )
            }

            let expected = context.flatMap { Data(hex: $0.approverKeyHex) }
            status = "Hold your card near the iPhone…"
            let signature = try await CardSigner.shared.sign(
                digest: [UInt8](hash),
                pin: pin,
                expectedPublicKey: expected.map { [UInt8]($0) }
            )

            status = "Broadcasting…"
            let result = try await api.submit(
                txId: prepared.txId,
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
}
