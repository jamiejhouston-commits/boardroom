import Foundation

protocol HermesRuntimeBridge {
    var mode: HermesRuntimeMode { get }
    func connect() async -> HermesRuntimeState
    func send(_ message: String) async -> AsyncStream<String>
}

struct EmbeddedHermesRuntimeBridge: HermesRuntimeBridge {
    let mode: HermesRuntimeMode = .embedded

    func connect() async -> HermesRuntimeState {
        .degraded("Embedded Hermes core needs an iOS-compatible runtime bundle before it can execute locally.")
    }

    func send(_ message: String) async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("Embedded runtime adapter received: \(message)")
            continuation.finish()
        }
    }
}

struct GatewayHermesRuntimeBridge: HermesRuntimeBridge {
    let mode: HermesRuntimeMode = .gateway
    var endpoint: URL?

    func connect() async -> HermesRuntimeState {
        guard endpoint != nil else {
            return .degraded("Gateway endpoint is not configured yet.")
        }
        return .ready
    }

    func send(_ message: String) async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("Gateway adapter is ready to send: \(message)")
            continuation.finish()
        }
    }
}

struct DesktopRelayHermesRuntimeBridge: HermesRuntimeBridge {
    let mode: HermesRuntimeMode = .desktopRelay

    func connect() async -> HermesRuntimeState {
        .degraded("Desktop relay pairing is not configured yet.")
    }

    func send(_ message: String) async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("Desktop relay adapter queued: \(message)")
            continuation.finish()
        }
    }
}
