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

    private let api = APIClient()
    private var pollTask: Task<Void, Never>?

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

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(silent: true)
                try? await Task.sleep(for: .seconds(2))
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
