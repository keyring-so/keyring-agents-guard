import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL."
        case .invalidResponse: return "The API returned an invalid response."
        case let .http(code, message): return "API \(code): \(message)"
        case let .decoding(error): return "Could not read the API response: \(error.localizedDescription)"
        }
    }
}

private struct APIErrorBody: Decodable {
    let error: String
}

struct APIClient {
    let baseURL: URL
    let token: String
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

    init(baseURL: URL = AppConfig.apiBaseURL, token: String = AppConfig.apiToken) {
        self.baseURL = baseURL
        self.token = token
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

    /// The API builds the unsigned approve/reject transaction and returns its hash.
    /// The app signs that hash with the card; the API never sees the key or the PIN.
    func prepare(action: String, id: String) async throws -> PrepareResponse {
        try await request(path: "/api/tx/\(action)/\(id)", method: "POST", body: [:])
    }

    func submit(txId: String, signatureHex: String) async throws -> SubmitResponse {
        try await request(
            path: "/api/tx/submit",
            method: "POST",
            body: ["txId": txId, "signatureHex": signatureHex]
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
            throw APIError.decoding(error)
        }
    }
}
