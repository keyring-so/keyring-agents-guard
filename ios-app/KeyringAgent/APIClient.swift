import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case decoding(Error, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL."
        case .invalidResponse: return "The API returned an invalid response."
        case let .http(code, message): return "API \(code): \(message)"
        case let .decoding(error, body):
            let suffix = body.isEmpty ? "" : " — server said: \(body)"
            return "Could not read the API response: \(error.localizedDescription)\(suffix)"
        }
    }
}

private struct APIErrorBody: Decodable {
    let error: String
}

struct APIClient {
    let baseURL: URL
    let token: String
    /// The user's NEAR account. Sent as X-User-Account; the API is multi-user.
    let account: String?
    private let session: URLSession

    /// Accepts "http(s)://host[:port]" with an optional trailing slash; anything else is rejected.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    init(baseURL: URL = AppConfig.apiBaseURL, token: String = AppConfig.apiToken, account: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.account = account
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func context() async throws -> AccountContext {
        try await request(path: "/api/context")
    }

    func pending() async throws -> [PendingSpend] {
        let response: PendingResponse = try await request(path: "/api/pending")
        return response.pending
    }

    /// Routing data (nonce, block hash, key). The app builds and hashes the transaction itself.
    func prepare(action: String, id: String) async throws -> PrepareResponse {
        try await request(path: "/api/tx/prepare/\(action)/\(id)", method: "POST", body: [:])
    }

    /// Relays the app's unsigned bytes and the card's signature. The server cannot change them.
    func submit(unsignedTxBase64: String, signatureHex: String) async throws -> SubmitResponse {
        try await request(
            path: "/api/tx/submit",
            method: "POST",
            body: ["unsignedTxBase64": unsignedTxBase64, "signatureHex": signatureHex]
        )
    }

    /// Ask the sponsor to create a fresh account with the card key and the agent key.
    func onboardSponsor(cardPublicKeyHex: String, agentPublicKey: String? = nil) async throws -> OnboardPrepare {
        var body = ["cardPublicKeyHex": cardPublicKeyHex]
        if let agentPublicKey { body["agentPublicKey"] = agentPublicKey }
        return try await request(path: "/api/onboard/sponsor", method: "POST", body: body)
    }

    /// Nonce, block hash, agent key, fee, and default policy for register/deposit.
    func prepareOnboarding(account: String, cardPublicKeyHex: String) async throws -> OnboardPrepare {
        try await request(
            path: "/api/onboard/prepare",
            method: "POST",
            body: ["account": account, "cardPublicKeyHex": cardPublicKeyHex]
        )
    }

    func fetchPair(code: String) async throws -> Pairing {
        try await request(path: "/api/pair/\(code)")
    }

    func completePair(code: String, account: String) async throws -> Pairing {
        try await request(
            path: "/api/pair/\(code)/complete",
            method: "POST",
            body: ["account": account]
        )
    }

    /// Whether the agent key is on the account and bound on the hub.
    func pairStatus(code: String, account: String) async throws -> PairStatus {
        try await request(path: "/api/pair/\(code)/status?account=\(account)")
    }

    /// Relay a card-signed onboarding transaction.
    func broadcast(unsignedTxBase64: String, signatureHex: String, publicKey: String) async throws -> SubmitResponse {
        try await request(
            path: "/api/broadcast",
            method: "POST",
            body: [
                "unsignedTxBase64": unsignedTxBase64,
                "signatureHex": signatureHex,
                "publicKey": publicKey,
            ]
        )
    }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: String]? = nil
    ) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let account, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "X-User-Account")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw APIError.http(http.statusCode, message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.decoding(error, String(body.prefix(240)))
        }
    }
}
