import Foundation
import SwiftUI

enum HermesRuntimeMode: String, CaseIterable, Identifiable {
    case embedded
    case gateway
    case desktopRelay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded: "Embedded Core"
        case .gateway: "Gateway"
        case .desktopRelay: "Desktop Relay"
        }
    }

    var subtitle: String {
        switch self {
        case .embedded: "Runs Hermes Agent in the app bundle through an embedded runtime."
        case .gateway: "Connects to `hermes dashboard` or a remote Hermes host."
        case .desktopRelay: "Pairs with a desktop install for files, terminals, and heavyweight sandboxes."
        }
    }
}

enum HermesRuntimeState: Equatable {
    case booting
    case ready
    case degraded(String)
    case offline(String)

    var title: String {
        switch self {
        case .booting: "Booting"
        case .ready: "Ready"
        case .degraded: "Limited"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch self {
        case .booting: .cyan
        case .ready: .green
        case .degraded: .orange
        case .offline: .red
        }
    }

    var detail: String {
        switch self {
        case .booting:
            "Preparing Hermes runtime."
        case .ready:
            "Hermes Agent runtime is available."
        case .degraded(let reason), .offline(let reason):
            reason
        }
    }
}

struct HermesRuntimeCapability: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var isAvailableOnDevice: Bool
}

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Author: String, Hashable, Codable {
        case user
        case hermes
        case system
    }

    var id = UUID()
    var author: Author
    var text: String
    var date: Date
    var speaker: String? = nil
    var accentHex: String? = nil
    var attachments: [ChatAttachment] = []
}

/// A photo or file the user attached to a chat message.
struct ChatAttachment: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable { case image, file }

    var id = UUID()
    var kind: Kind
    var filename: String
    var data: Data
    /// Extracted text for readable files — this is what the agent receives.
    var textContent: String? = nil
}

extension Array where Element == ChatAttachment {
    /// What the relay/agent receives for the attachments. Text files deliver
    /// their content; binaries and images are referenced by name.
    var payloadSuffix: String {
        guard !isEmpty else { return "" }
        var out = ""
        for a in self {
            switch a.kind {
            case .file:
                if let text = a.textContent {
                    out += "\n\n[Attached file: \(a.filename)]\n\(text)"
                } else {
                    out += "\n\n[Attached file: \(a.filename) — binary, \(a.data.count) bytes]"
                }
            case .image:
                out += "\n\n[Attached image: \(a.filename)]"
            }
        }
        return out
    }
}
