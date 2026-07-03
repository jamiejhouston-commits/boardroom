import SwiftUI

/// The voice-cost policy, owner-facing. Internal voice (calls, meetings,
/// office chatter) is ALWAYS free — Piper on the Mac, Apple on device.
/// The paid ElevenLabs voice serves only external, revenue-facing work,
/// is off by default, confirms before use, and shows its budget here.
struct VoiceSettingsView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController

    @AppStorage(VoicePolicy.premiumEnabledKey) private var premiumEnabled = false
    @AppStorage(VoicePolicy.confirmPremiumKey) private var confirmPremium = true

    @State private var usage: VoiceUsage?
    @State private var confirmingTest = false
    @State private var testing = false
    private let voice = AgentVoice()

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Free voice — always on")
                            .font(.subheadline.weight(.semibold))
                        Text("Every internal conversation — 1:1 calls, boardroom meetings, office chatter, voice notes, status updates — speaks on the free neural voice (Piper on your Mac; Apple's voice if the relay is away). It never costs a cent.")
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(HermesTheme.emerald)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Internal voice")
            }

            Section {
                Toggle(isOn: $premiumEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow paid voice for sales & revenue")
                        Text("Outbound sales calls, customer calls, pitches, demo calls, and marketing voice assets only. Never internal chatter.")
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                }
                .tint(HermesTheme.gold)

                Toggle(isOn: $confirmPremium) {
                    Text("Confirm before each paid generation")
                }
                .tint(HermesTheme.gold)
                .disabled(!premiumEnabled)

                if premiumEnabled {
                    HStack {
                        PaidVoiceBadge()
                        Spacer()
                        Button(testing ? "Playing…" : "Test the paid voice") {
                            if confirmPremium {
                                confirmingTest = true
                            } else {
                                runTest()
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(testing)
                    }
                }
            } header: {
                Text("Premium voice (ElevenLabs)")
            } footer: {
                Text("The relay enforces this too: only requests marked as revenue-facing can reach ElevenLabs, and only within your budget below. Over budget, it falls back to the free voice automatically.")
            }

            if let usage {
                Section("Budget") {
                    if usage.premiumConfigured {
                        budgetRow(label: "Today",
                                  used: usage.usedToday, budget: usage.dailyCharBudget)
                        budgetRow(label: "This week",
                                  used: usage.usedWeek, budget: usage.weeklyCharBudget)
                        Text("Budgets are characters of speech. Change them in ~/.hermes/elevenlabs.json on your Mac.")
                            .font(.caption2)
                            .foregroundStyle(HermesTheme.textSecondary)
                    } else {
                        Text("ElevenLabs isn't configured on the relay — the paid voice is unavailable and everything speaks free.")
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUsage() }
        .refreshable { await loadUsage() }
        .confirmationDialog("Use the paid ElevenLabs voice?",
                            isPresented: $confirmingTest, titleVisibility: .visible) {
            Button("Play paid sample") { runTest() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This spends a few characters of your ElevenLabs budget.")
        }
    }

    private func budgetRow(label: String, used: Int, budget: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(used.formatted()) / \(budget.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(used >= budget ? .orange : HermesTheme.textSecondary)
            }
            ProgressView(value: Double(min(used, budget)), total: Double(max(budget, 1)))
                .tint(used >= budget ? .orange : HermesTheme.gold)
        }
        .padding(.vertical, 2)
    }

    private func runTest() {
        testing = true
        Task {
            await voice.speak("This is the premium sales voice, reserved for revenue.",
                              seedFrom: "voice-test", voice: "en_US-ryan-medium",
                              relay: runtime.relayConfiguration, premium: true)
            testing = false
            await loadUsage()
        }
    }

    private func loadUsage() async {
        guard runtime.relayConfiguration.isConfigured else { return }
        usage = try? await HermesRelayClient(configuration: runtime.relayConfiguration)
            .voiceUsage()
    }
}
