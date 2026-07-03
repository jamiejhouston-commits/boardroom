import SwiftUI

/// The voice-cost policy, app side. Internal communication — owner↔agent
/// calls, meetings, office chatter, status updates — ALWAYS speaks on the
/// free voice (the Mac's local Piper, Apple on device). The paid ElevenLabs
/// voice exists only for external, revenue-facing work (sales calls, customer
/// calls, demos, marketing assets), is OFF until the owner enables it, asks
/// for confirmation before each use, and is budget-capped on the relay —
/// over budget it falls back to the free voice automatically.
enum VoicePolicy {
    static let premiumEnabledKey = "voice.premiumEnabled"
    static let confirmPremiumKey = "voice.confirmPremium"

    /// Owner's master switch for the paid voice. Default OFF.
    static var premiumEnabled: Bool {
        UserDefaults.standard.bool(forKey: premiumEnabledKey)
    }

    /// Ask before every paid generation. Default ON.
    static var confirmBeforePremium: Bool {
        UserDefaults.standard.object(forKey: confirmPremiumKey) as? Bool ?? true
    }
}

/// The visible "this costs money" marker — shown wherever the paid voice
/// is used or offered. Muted gold, per the app's premium palette.
struct PaidVoiceBadge: View {
    var body: some View {
        Label("Paid voice · ElevenLabs", systemImage: "waveform.badge.exclamationmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(HermesTheme.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HermesTheme.gold.opacity(0.14), in: Capsule())
    }
}
