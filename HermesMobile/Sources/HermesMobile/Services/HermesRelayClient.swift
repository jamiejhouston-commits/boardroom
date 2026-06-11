import Foundation

/// Hermes jobs (briefings, debate turns, org genesis) routinely run past
/// URLSession's default 60s request timeout — the relay itself allows 240s.
/// This session waits as long as the relay does.
extension URLSession {
    static let hermesPatient: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300    // max quiet time between bytes
        config.timeoutIntervalForResource = 900   // max total per request
        return URLSession(configuration: config)
    }()
}

struct HermesRelayClient {
    var configuration: HermesRelayConfiguration
    var session: URLSession = .hermesPatient

    func health() async throws -> RelayHealth {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }

        let url = baseURL.appending(path: "health")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RelayHealth.self, from: data)
    }

    func send(_ message: String) async throws -> String {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }

        var request = URLRequest(url: baseURL.appending(path: "chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                message: message,
                profile: configuration.profile,
                session: configuration.sessionName
            )
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ChatResponse.self, from: data).reply
    }

    /// `fast: true` asks the relay for a single model turn (no agent tool
    /// loop) — used by voice calls where latency matters more than tools.
    func stream(_ message: String, sessionKey: String? = nil, fast: Bool = false) -> AsyncThrowingStream<RelayStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let baseURL = configuration.baseURL else {
                        throw HermesRelayError.invalidURL
                    }

                    var request = URLRequest(url: baseURL.appending(path: "chat/stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(
                            message: message,
                            profile: configuration.profile,
                            session: sessionKey ?? configuration.sessionName,
                            fast: fast ? true : nil
                        )
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw HermesRelayError.server("Streaming request failed.")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8) else { continue }
                        let event = try JSONDecoder().decode(RelayStreamEvent.self, from: data)
                        continuation.yield(event)
                        if event.type == .done || event.type == .error {
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Company engine (autonomous boardroom)

    func companyState() async throws -> CompanyState {
        try await companyGET(path: "company")
    }

    func companyInitiativeDetail(id: String) async throws -> CompanyInitiative {
        try await companyGET(path: "company/initiative/\(id)")
    }

    func companyStart(thesis: String) async throws -> CompanyState {
        try await companyPOST(path: "company/start", body: ["thesis": thesis])
    }

    func companyHalt() async throws -> CompanyState {
        try await companyPOST(path: "company/halt", body: [:])
    }

    func companyGate(id: String, decision: CompanyDecision, note: String) async throws -> CompanyState {
        try await companyPOST(path: "company/gate",
                              body: ["id": id, "decision": decision.rawValue, "note": note])
    }

    private func companyGET<T: Decodable>(path: String) async throws -> T {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try Self.companyDecoder.decode(T.self, from: data)
    }

    private func companyPOST<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try Self.companyDecoder.decode(T.self, from: data)
    }

    private static let companyDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(RelayErrorResponse.self, from: data).error) ?? "HTTP \(http.statusCode)"
            throw HermesRelayError.server(error)
        }
    }
}

struct RelayHealth: Codable, Equatable {
    var ok: Bool
    var service: String
    var profiles: [String]
}

struct RelayStreamEvent: Codable, Equatable {
    enum EventType: String, Codable {
        case start
        case delta
        case done
        case error
    }

    var type: EventType
    var text: String?
    var reply: String?
    var message: String?
    var profile: String?
    var session: String?
    var returncode: Int?
}

private struct ChatRequest: Codable {
    var message: String
    var profile: String
    var session: String
    var fast: Bool? = nil
}

private struct ChatResponse: Codable {
    var reply: String
    var profile: String?
    var session: String?
}

private struct RelayErrorResponse: Codable {
    var error: String
}

enum HermesRelayError: LocalizedError {
    case invalidURL
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid Hermes relay URL."
        case .server(let message):
            message
        }
    }
}
