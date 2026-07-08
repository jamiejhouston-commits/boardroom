import CallKit
import Foundation
import PushKit
import UIKit

/// "The company calls you" — native incoming-call UI for boardroom calls.
/// Two ways a call arrives: a 10s poll of the relay's /call/pending while the
/// app runs, and a PushKit VoIP push (dormant until the owner configures APNs
/// keys on the relay). Either way the phone rings with the full-screen
/// CallKit UI; answering sets `activeCall`, which RootView presents as the
/// existing AgentCallView voice experience.
@MainActor
final class CallCoordinator: NSObject, ObservableObject {

    /// The answered call RootView presents the voice-call cover for.
    struct ActiveCall: Identifiable, Equatable {
        let id: String        // relay call id
        let caller: String
        let reason: String
        let callUUID: UUID    // CallKit's handle for this call
    }

    @Published var activeCall: ActiveCall?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var voipRegistry: PKPushRegistry?
    private var pollTask: Task<Void, Never>?
    /// Every call id ever rung — one relay call rings exactly once, even when
    /// the poll and a VoIP push both deliver it.
    private var seenCallIDs: Set<String> = []
    /// Calls currently ringing, keyed by their CallKit UUID.
    private var ringing: [UUID: (id: String, caller: String, reason: String)] = [:]

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.iconTemplateImageData = UIImage(named: "AppIcon")?.pngData()
            ?? UIImage(systemName: "building.2.crop.circle.fill")?.pngData()
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: Ringing

    /// Present the native full-screen incoming-call UI. Deduped by call id.
    func reportIncomingCall(id: String, caller: String, reason: String) {
        guard !seenCallIDs.contains(id) else { return }
        seenCallIDs.insert(id)

        let uuid = UUID()
        ringing[uuid] = (id, caller, reason)

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = "\(caller) — Boardroom"
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.ringing[uuid] = nil }
        }

        // Unanswered rings count as declined — the relay stops waiting.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.timeOutRing(uuid: uuid)
        }
    }

    private func timeOutRing(uuid: UUID) {
        guard let call = ringing.removeValue(forKey: uuid) else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
        ack(id: call.id, status: "declined")
    }

    /// The voice-call cover was dismissed — tell CallKit the call is over.
    func endActiveCall() {
        guard let call = activeCall else { return }
        activeCall = nil
        callController.request(CXTransaction(action: CXEndCallAction(call: call.callUUID))) { _ in }
    }

    // MARK: Poll fallback (works with zero APNs setup, app open)

    /// Poll /call/pending every 10s. Safe to start before the relay is
    /// configured — each tick re-reads the persisted config.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPending()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func checkPending() async {
        let relay = HermesRuntimeController.persistedRelayConfiguration()
        guard relay.isConfigured,
              let call = try? await HermesRelayClient(configuration: relay).callPending(),
              let id = call.id, !id.isEmpty,
              (call.status ?? "ringing") == "ringing" else { return }
        reportIncomingCall(id: id, caller: call.caller ?? "Lena", reason: call.reason ?? "")
    }

    // MARK: PushKit VoIP (rings even with the app closed — dormant until the
    // relay has APNs keys; registration + token POST are harmless without them)

    func registerForVoIPPush() {
        guard voipRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    // MARK: Relay ack

    private func ack(id: String, status: String) {
        let relay = HermesRuntimeController.persistedRelayConfiguration()
        guard relay.isConfigured else { return }
        Task {
            try? await HermesRelayClient(configuration: relay).callAck(id: id, status: status)
        }
    }
}

// MARK: - CXProviderDelegate (callbacks can arrive off-main — hop to @MainActor)

extension CallCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            self.ringing.removeAll()
            self.activeCall = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // CXAction isn't Sendable — take the UUID, fulfill here, hop with values only.
        let uuid = action.callUUID
        action.fulfill()
        Task { @MainActor in
            if let call = self.ringing.removeValue(forKey: uuid) {
                self.activeCall = ActiveCall(id: call.id, caller: call.caller,
                                             reason: call.reason, callUUID: uuid)
                self.ack(id: call.id, status: "answered")
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        action.fulfill()
        Task { @MainActor in
            // Still in `ringing` = declined before answer. Otherwise it's the
            // in-call end (ours via endActiveCall, or the system's) — already acked.
            if let call = self.ringing.removeValue(forKey: uuid) {
                self.ack(id: call.id, status: "declined")
            }
            if self.activeCall?.callUUID == uuid {
                self.activeCall = nil
            }
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension CallCoordinator: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didUpdate pushCredentials: PKPushCredentials,
                                  for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task {
            let relay = HermesRuntimeController.persistedRelayConfiguration()
            guard relay.isConfigured else { return }
            try? await HermesRelayClient(configuration: relay).registerVoIPPushToken(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType,
                                  completion: @escaping () -> Void) {
        // iOS kills apps that receive a VoIP push without reporting a call
        // BEFORE this method returns — so report synchronously. Safe: the
        // registry was created with queue: .main, so we're on the main actor.
        let dict = payload.dictionaryPayload
        let id = dict["id"] as? String ?? UUID().uuidString
        let caller = dict["caller"] as? String ?? "Boardroom"
        let reason = dict["reason"] as? String ?? ""
        MainActor.assumeIsolated {
            self.reportIncomingCall(id: id, caller: caller, reason: reason)
        }
        completion()
    }
}
