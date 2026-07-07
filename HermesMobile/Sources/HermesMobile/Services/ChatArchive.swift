import Foundation

/// Persists chat transcripts per relay session key, so closing a chat no
/// longer wipes it while the relay-side session still remembers everything
/// (that mismatch caused persona re-injection and prompt drift).
enum ChatArchive {
    struct Record: Codable {
        var messages: [ChatMessage]
        var introSent: Bool
        /// Company chat introduces each addressed agent once — per-agent flags.
        var introAgents: [String]? = nil
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermesMobile/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func url(for key: String) -> URL {
        // Session keys are filesystem-hostile ("default:company-ceo-chat").
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    static func load(key: String) -> Record? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(key: String, messages: [ChatMessage], introSent: Bool,
                     introAgents: [String]? = nil) {
        // Attachments can be megabytes; the transcript archive keeps the
        // conversation, not the binary payloads.
        var slim = messages.suffix(200).map { message in
            var m = message
            m.attachments = m.attachments.map { attachment in
                var a = attachment
                a.data = Data()
                return a
            }
            return m
        }
        // Drop a still-empty trailing placeholder bubble from a send in flight.
        if let last = slim.last, last.author == .hermes,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            slim.removeLast()
        }
        let record = Record(messages: Array(slim), introSent: introSent, introAgents: introAgents)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    static func clear(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }
}
