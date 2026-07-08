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
                        if let http = response as? HTTPURLResponse,
                           http.statusCode == 401 || http.statusCode == 403 {
                            throw HermesRelayError.unauthorized
                        }
                        throw HermesRelayError.server("Streaming request failed.")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              // Tolerant parse: a malformed frame (split JSON,
                              // stray keepalive payload) is skipped, not fatal
                              // to the whole reply.
                              let event = try? JSONDecoder().decode(RelayStreamEvent.self, from: data)
                        else { continue }
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

    /// Consume a chat stream to completion — THE one place stream events are
    /// interpreted. `onDelta` receives the growing text for live rendering;
    /// the return value is the final reply, never empty. If the stream dies
    /// before ANY text arrived, one automatic retry runs (safe: nothing was
    /// shown yet). A relay `.error` event surfaces as a thrown error.
    func collect(_ message: String,
                 sessionKey: String? = nil,
                 fast: Bool = false,
                 skills: [String] = [],
                 onDelta: @escaping @MainActor (String) -> Void = { _ in }) async throws -> String {
        do {
            return try await collectOnce(message, sessionKey: sessionKey, fast: fast,
                                         skills: skills, onDelta: onDelta)
        } catch is CollectRetryable {
            // ponytail: single retry, only on a zero-byte transport failure
            return try await collectOnce(message, sessionKey: sessionKey, fast: fast,
                                         skills: skills, onDelta: onDelta)
        }
    }

    /// What `collect` returns when a turn genuinely produced no text —
    /// callers that must NOT persist a non-answer compare against this.
    static let noResponseFallback = "(no response — try again)"

    /// Wrapped cause for "stream failed before any text" — retried once.
    private struct CollectRetryable: Error { let cause: Error }

    private func collectOnce(_ message: String,
                             sessionKey: String?,
                             fast: Bool,
                             skills: [String],
                             onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        var accumulated = ""
        do {
            for try await event in stream(message, sessionKey: sessionKey, fast: fast, skills: skills) {
                switch event.type {
                case .start:
                    continue
                case .delta:
                    if let text = event.text, !text.isEmpty {
                        accumulated += text
                        let snapshot = accumulated
                        await onDelta(snapshot)
                    }
                case .done:
                    let final = event.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let body = final.isEmpty
                        ? accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                        : final
                    return body.isEmpty ? Self.noResponseFallback : body
                case .error:
                    throw HermesRelayError.server(event.message ?? "The relay reported an error.")
                }
            }
        } catch let error as HermesRelayError {
            throw error   // relay-reported — real, do not retry
        } catch where accumulated.isEmpty {
            throw CollectRetryable(cause: error)   // transport died before any text
        } catch {
            // Transport died mid-reply: keep what arrived, say so honestly.
            return accumulated + "\n\n⚠︎ Connection dropped mid-reply — ask me to continue."
        }
        // Stream ended without a done event — return what we have, honestly.
        let body = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? Self.noResponseFallback : body
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

    /// Set the working hours. quietStart == quietEnd = no quiet hours (24/7).
    func companySetWorkingHours(quietStart: Int, quietEnd: Int) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/config",
                                  json: ["quiet_start": quietStart, "quiet_end": quietEnd] as [String: Any])
    }

    /// Switch the production line's target platform (HQ Production Bay).
    func companySetPlatform(_ platform: ProductionPlatform) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/config",
                                  json: ["platform": platform.rawValue] as [String: Any])
    }

    /// Ask the company a question — returns the created ask (poll its detail).
    func companyAsk(question: String) async throws -> CompanyAsk {
        try await companyPOST(path: "company/ask", body: ["question": question])
    }

    func companyAskDetail(id: String) async throws -> CompanyAsk {
        try await companyGET(path: "company/ask/\(id)")
    }

    /// The company vault as a graph (notes + wikilinks) for the knowledge-graph view.
    /// Includes the owner's Obsidian vault when the relay has one configured.
    func companyVaultGraph() async throws -> VaultGraph {
        try await companyGET(path: "company/vault/graph")
    }

    /// One vault note's markdown body (company vault or Obsidian) — the
    /// second brain, readable from the phone.
    func companyVaultNote(id: String) async throws -> VaultNoteContent {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var components = URLComponents(url: baseURL.appending(path: "company/vault/note"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components?.url else { throw HermesRelayError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try Self.companyDecoder.decode(VaultNoteContent.self, from: data)
    }

    // MARK: Deliverables — read the company's real work product

    /// Relative paths + sizes of everything the team built for an initiative.
    func companyDeliverableFiles(id: String) async throws -> [DeliverableFile] {
        struct FileManifest: Codable { var files: [DeliverableFile] }
        let manifest: FileManifest = try await companyGET(path: "company/initiative/\(id)/files")
        return manifest.files
    }

    /// One deliverable file's bytes (auth-guarded raw fetch, not JSON).
    func companyDeliverableData(id: String, path: String) async throws -> Data {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var request = URLRequest(url: baseURL.appending(path: "company/file/\(id)/\(path)"))
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    // MARK: Games Studio (the first Boardroom division)

    func gamesState() async throws -> GamesStudioState {
        try await companyGET(path: "games")
    }

    func gamesGameDetail(id: String) async throws -> StudioGame {
        try await companyGET(path: "games/game/\(id)")
    }

    func gamesStart() async throws -> GamesStudioState {
        try await companyPOSTJSON(path: "games/start", json: [String: Any]())
    }

    func gamesHalt() async throws -> GamesStudioState {
        try await companyPOSTJSON(path: "games/halt", json: [String: Any]())
    }

    /// Owner pitches a game idea into the studio pipeline.
    func gamesConcept(title: String, line: String, pitch: String) async throws -> GamesStudioState {
        try await companyPOSTJSON(path: "games/concept",
                                  json: ["title": title, "line": line, "pitch": pitch] as [String: Any])
    }

    /// The arcade cabinet reports the owner's best score for a game.
    func gamesScore(id: String, score: Int) async throws -> GamesStudioState {
        try await companyPOSTJSON(path: "games/score",
                                  json: ["id": id, "score": score] as [String: Any])
    }

    /// Resume a paused game — the studio gets a fresh budget on the same title.
    func gamesResume(id: String) async throws -> GamesStudioState {
        try await companyPOSTJSON(path: "games/resume", json: ["id": id] as [String: Any])
    }

    /// Per-division rollup for the holding dashboard (relay pass B — 404s
    /// until it lands; callers show a graceful empty state).
    func companyDivisions() async throws -> [DivisionInfo] {
        struct Manifest: Codable { var divisions: [DivisionInfo] }
        let manifest: Manifest = try await companyGET(path: "company/divisions")
        return manifest.divisions
    }

    /// Live portfolio metrics (RevenueCat via the relay) — what the shipped
    /// products actually earn. `configured == false` means no key on the Mac.
    func companyRevenue() async throws -> RevenueSummary {
        try await companyGET(path: "company/revenue")
    }

    /// Paid-voice budget status for the Voice settings screen.
    func voiceUsage() async throws -> VoiceUsage {
        try await companyGET(path: "voice/usage")
    }

    // MARK: Demo Day gallery — see the product before shipping it

    /// Filenames of the screenshots the builder captured for this initiative.
    func companyDemoFiles(id: String) async throws -> [String] {
        struct DemoManifest: Codable { var files: [String] }
        let manifest: DemoManifest = try await companyGET(path: "company/initiative/\(id)/demo")
        return manifest.files
    }

    /// One demo screenshot's bytes (auth-guarded raw fetch, not JSON).
    func companyDemoImage(id: String, filename: String) async throws -> Data {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var request = URLRequest(url: baseURL.appending(path: "company/demo/\(id)/\(filename)"))
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    /// Register this device for real APNs push from the relay — gate
    /// decisions reach the phone anywhere, not just on the home Wi-Fi poll.
    func registerPushToken(_ token: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "push/register",
                                                  body: ["token": token])
    }

    // MARK: Install Day — put an agent-built app on the owner's phone

    /// Ask the relay to archive + ad-hoc-export the initiative's app.
    func installExport(id: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "company/initiative/\(id)/export-ipa",
                                                  body: [:])
    }

    /// Export status; `installUrl` is an itms-services link when ready.
    func installStatus(id: String) async throws -> InstallStatus {
        try await companyGET(path: "company/initiative/\(id)/install")
    }

    // MARK: TestFlight — the company ships to Apple (owner-pressed only)

    /// Kick the archive + App Store upload for a shipped initiative.
    func submitTestFlight(id: String) async throws -> SubmitStatus {
        try await companyPOST(path: "company/initiative/\(id)/submit-testflight",
                              body: [:])
    }

    /// TestFlight submit status: submitting/submitted/failed, or an honest
    /// `available: false` naming the missing credential.
    func submitStatus(id: String) async throws -> SubmitStatus {
        try await companyGET(path: "company/initiative/\(id)/testflight")
    }

    // MARK: Watch the team work

    /// The last thing each working initiative's agent produced — the honest
    /// over-the-shoulder feed behind "watch them work".
    func companyLive() async throws -> [LiveWorkEntry] {
        struct Manifest: Codable { var working: [LiveWorkEntry] }
        let manifest: Manifest = try await companyGET(path: "company/live")
        return manifest.working
    }

    // MARK: Portfolio adoption — existing apps join the company

    /// Bring one of the owner's existing apps (a folder on the Mac) under
    /// company maintenance. The relay validates the path.
    func adoptPortfolio(path: String, name: String = "",
                        division: String = "") async throws {
        let _: CompanyAck = try await companyPOST(
            path: "company/portfolio/adopt",
            body: ["path": path, "name": name, "division": division])
    }

    // MARK: Incoming calls — the company calls YOU

    /// The relay's current pending call, if any (`{}` when the line is quiet,
    /// hence every field optional).
    func callPending() async throws -> PendingCall {
        try await companyGET(path: "call/pending")
    }

    /// Tell the relay how the owner handled the ring: "answered" | "declined".
    func callAck(id: String, status: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "call/ack",
                                                  body: ["id": id, "status": status])
    }

    /// PushKit VoIP token — lets the relay ring the phone even when the app
    /// is closed (dormant until APNs keys exist on the Mac).
    func registerVoIPPushToken(_ token: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "push/register-voip",
                                                  body: ["token": token])
    }

    /// Owner-triggered test ring (Settings → "Test: have Lena call me").
    func requestCall(caller: String, reason: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "call/request",
                                                  body: ["caller": caller, "reason": reason])
    }

    // MARK: Schedules (the Cron)

    func companyAddSchedule(title: String, kind: String, text: String, cadence: String,
                            atHour: Int, atMinute: Int, weekday: Int) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/schedules", json: [
            "title": title, "kind": kind, "text": text, "cadence": cadence,
            "at_hour": atHour, "at_minute": atMinute, "weekday": weekday] as [String: Any])
    }

    /// One-shot office-hours meeting at a real calendar time — makes a
    /// scheduled meeting actually CONVENE instead of just alarming.
    func companyAddOneShotMeeting(topic: String, at date: Date) async throws -> CompanyState {
        try await companyPOSTJSON(path: "company/schedules", json: [
            "title": topic, "kind": "meeting", "text": topic,
            "cadence": "once", "at_ts": date.timeIntervalSince1970] as [String: Any])
    }

    /// Convene the leadership on a topic right now.
    func conveneMeeting(topic: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "company/meeting/convene",
                                                  body: ["topic": topic])
    }

    /// Distill a finished meeting into Kanban action items (background on the Mac).
    func meetingActions(id: String) async throws {
        let _: CompanyAck = try await companyPOST(path: "company/meeting/\(id)/actions",
                                                  body: [:])
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
            if http.statusCode == 401 || http.statusCode == 403 {
                throw HermesRelayError.unauthorized
            }
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

/// One file the team built for an initiative, as listed by the relay.
struct DeliverableFile: Codable, Equatable, Identifiable, Hashable {
    var path: String
    var size: Int

    var id: String { path }
    var filename: String { (path as NSString).lastPathComponent }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif"].contains((path as NSString).pathExtension.lowercased())
    }

    var sizeLabel: String {
        size >= 1_048_576 ? String(format: "%.1f MB", Double(size) / 1_048_576)
            : size >= 1024 ? "\(size / 1024) KB" : "\(size) B"
    }
}

/// A call the relay wants to place to the owner. `{}` = no pending call.
struct PendingCall: Codable, Equatable {
    var id: String?
    var caller: String?
    var reason: String?
    var created: Double?
    var status: String?    // "ringing" while it should ring
}

/// One second-brain note's body (company vault or Obsidian).
struct VaultNoteContent: Codable, Equatable {
    var id: String
    var title: String
    var content: String
    var source: String        // "company" | "obsidian"
    var modified: Double?
}

/// Install Day export state for one initiative.
struct InstallStatus: Codable, Equatable {
    var available: Bool
    var status: String?       // "exporting" | "ready" | "failed"
    var installUrl: String?   // itms-services://… when ready
    var note: String?
}

/// TestFlight submit state for one initiative.
struct SubmitStatus: Codable, Equatable {
    var available: Bool
    var status: String?       // "submitting" | "submitted" | "failed"
    var note: String?
}

/// One working initiative's latest agent output (`GET /company/live`).
struct LiveWorkEntry: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var stage: String
    var phase: String?
    var role: String?         // who's at the desk right now
    var ts: String?
    var text: String?         // the tail of their last turn
    var callsUsed: Int?
}

/// What the shipped portfolio earns, fetched by the relay from RevenueCat.
struct RevenueSummary: Codable, Equatable {
    var configured: Bool
    var metrics: [RevenueMetric]
    var brief: String
    var note: String?
    var fetched: Double?
}

/// Paid-voice (ElevenLabs) budget status, enforced on the relay.
struct VoiceUsage: Codable, Equatable {
    var premiumConfigured: Bool
    var dailyCharBudget: Int
    var weeklyCharBudget: Int
    var usedToday: Int
    var usedWeek: Int
}

struct RevenueMetric: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var value: Double
    var unit: String

    var display: String {
        unit == "$"
            ? String(format: "$%.2f", value)
            : String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }
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
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid Hermes relay URL."
        case .unauthorized:
            "Mac relay rejected the saved token. Re-pair in Settings then Mac Relay (scan the QR from the relay /pair page)."
        case .server(let message):
            message
        }
    }
}
