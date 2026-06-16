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
    /// `skills` is a comma-joined loadout passed to `hermes chat -s`.
    func stream(_ message: String, sessionKey: String? = nil, fast: Bool = false,
                skills: [String] = []) -> AsyncThrowingStream<RelayStreamEvent, Error> {
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
                            fast: fast ? true : nil,
                            skills: skills.isEmpty ? nil : skills.joined(separator: ",")
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

    func companyMeetingDetail(id: String) async throws -> CompanyMeeting {
        try await companyGET(path: "company/meeting/\(id)")
    }

    /// Owner speaks into a live/recent meeting; agents respond to it.
    func companyMeetingSay(id: String, text: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "company/meeting/\(id)/say",
                                                  body: ["text": text])
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

    /// Reopen a finished initiative for more work — same team, same codebase.
    func companyIterate(id: String, instruction: String) async throws -> CompanyState {
        try await companyPOST(path: "company/iterate",
                              body: ["id": id, "instruction": instruction])
    }

    /// Owner pitches an idea (e.g. a voice memo) — seeded as an initiative.
    func companyDirective(text: String) async throws -> CompanyState {
        try await companyPOST(path: "company/directive", body: ["text": text])
    }

    /// Set the investment thesis without toggling the company on/off.
    func companySetThesis(_ thesis: String) async throws -> CompanyState {
        try await companyPOST(path: "company/thesis", body: ["thesis": thesis])
    }

    /// Ask the company a question — returns the created ask (poll its detail).
    func companyAsk(question: String) async throws -> CompanyAsk {
        try await companyPOST(path: "company/ask", body: ["question": question])
    }

    func companyAskDetail(id: String) async throws -> CompanyAsk {
        try await companyGET(path: "company/ask/\(id)")
    }

    // MARK: Schedules (the Cron)

    func companyAddSchedule(title: String, kind: String, text: String, cadence: String,
                            atHour: Int, atMinute: Int, weekday: Int) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/schedules", json: [
            "title": title, "kind": kind, "text": text, "cadence": cadence,
            "at_hour": atHour, "at_minute": atMinute, "weekday": weekday] as [String: Any])
    }

    func companyDeleteSchedule(id: String) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/schedule/delete", json: ["id": id] as [String: Any])
    }

    func companyToggleSchedule(id: String, enabled: Bool) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/schedule/toggle",
                                  json: ["id": id, "enabled": enabled] as [String: Any])
    }

    // MARK: Kanban task backlog

    /// Hand the team a list of tasks (one per line) for the Kanban board.
    func companyAddTasks(_ texts: [String]) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/tasks", json: ["tasks": texts] as [String: Any])
    }

    /// Flip the "Kanban List" toggle — on = work the owner's list, off = own ideas.
    func companyTaskMode(on: Bool) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/tasks/mode", json: ["on": on] as [String: Any])
    }

    /// Clear the finished column.
    func companyClearDoneTasks() async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/tasks/clear", json: [String: Any]())
    }

    /// Remove one task from the board.
    func companyDeleteTask(id: String) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/task/delete", json: ["id": id] as [String: Any])
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

    /// Like companyPOST but carries real JSON types (arrays, bools) — needed for
    /// task lists and the on/off toggle, which a [String: String] body can't express.
    private func companyPOSTJSON<T: Decodable>(path: String, json: [String: Any]) async throws -> T {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
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
    var skills: String? = nil
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
