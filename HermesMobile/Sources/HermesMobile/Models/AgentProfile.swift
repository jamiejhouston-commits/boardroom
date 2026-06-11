import Foundation
import SwiftUI

enum AgentStatus: String, CaseIterable, Codable, Identifiable {
    case active
    case thinking
    case delegated
    case idle
    case blocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Active"
        case .thinking: "Thinking"
        case .delegated: "Delegated"
        case .idle: "Idle"
        case .blocked: "Blocked"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .thinking: .cyan
        case .delegated: .indigo
        case .idle: .secondary
        case .blocked: .red
        }
    }
}

enum SandboxBackend: String, CaseIterable, Codable, Identifiable {
    case local
    case docker
    case ssh
    case singularity
    case modal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ConnectorSurface: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var isConnected: Bool
    var unreadCount: Int

    static let defaults: [ConnectorSurface] = [
        .init(id: "telegram", name: "Telegram", isConnected: true, unreadCount: 4),
        .init(id: "discord", name: "Discord", isConnected: true, unreadCount: 12),
        .init(id: "slack", name: "Slack", isConnected: false, unreadCount: 0),
        .init(id: "whatsapp", name: "WhatsApp", isConnected: false, unreadCount: 0),
        .init(id: "signal", name: "Signal", isConnected: false, unreadCount: 0),
        .init(id: "email", name: "Email", isConnected: true, unreadCount: 2),
        .init(id: "cli", name: "CLI", isConnected: true, unreadCount: 0)
    ]
}

struct AgentJob: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var detail: String
    var progress: Double
    var priority: String
    var dueLabel: String
}

struct AgentProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var handle: String
    var role: String
    var status: AgentStatus
    var accentHex: String
    var backend: SandboxBackend
    var memorySummary: String
    var soulMarkdown: String
    var skills: [String]
    var connectors: [ConnectorSurface]
    var jobs: [AgentJob]
    var lastActive: Date

    var initials: String {
        handle
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

struct WarRoomEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var agentID: UUID
    var timestamp: Date
    var title: String
    var detail: String
    var kind: EventKind

    enum EventKind: String, Codable {
        case thought
        case tool
        case memory
        case delegation
        case schedule
        case blocked
    }
}
