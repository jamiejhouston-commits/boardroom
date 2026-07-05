import Foundation

/// Window into the Games Studio division running on the Mac relay. Fetches state
/// and records the owner's arcade high score. When the relay is unreachable it
/// falls back to the bundled flagship state so the Games Production Room is fully
/// alive offline (the flagship game genuinely ships in the bundle).
@MainActor
final class GamesStudioStore: ObservableObject {
    @Published private(set) var state: GamesStudioState = .flagship
    @Published private(set) var isLoading = false
    @Published private(set) var isLive = false          // true once the relay answered
    @Published var errorMessage: String?

    /// The owner's best score on the flagship cabinet, persisted on-device so the
    /// score survives offline play (mirrors the relay copy when connected).
    private static let bestKey = "gamesStudio.best.SkylineStack"

    var currentGame: StudioGame? { state.currentGame }

    /// The best local arcade score (device-side source of truth for offline play).
    var localBest: Int {
        UserDefaults.standard.integer(forKey: Self.bestKey)
    }

    func refresh(relay: HermesRelayConfiguration) async {
        guard relay.isConfigured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var fresh = try await HermesRelayClient(configuration: relay).gamesState()
            // The relay is the source of truth, but if it somehow has no games
            // (never started), keep the bundled flagship so the room isn't empty.
            if fresh.games.isEmpty { fresh.games = GamesStudioState.flagship.games }
            state = fresh
            isLive = true
            errorMessage = nil
        } catch {
            // Offline / not paired → the bundled flagship. Not an error the owner
            // needs shoved in their face; the room stays beautiful and playable.
            state = .flagship
            isLive = false
            errorMessage = nil
        }
    }

    /// Start / stop the autonomous studio.
    func setEnabled(_ enabled: Bool, relay: HermesRelayConfiguration) async {
        guard relay.isConfigured else { return }
        do {
            let client = HermesRelayClient(configuration: relay)
            state = enabled ? try await client.gamesStart() : try await client.gamesHalt()
            isLive = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Owner pitches a new game into the pipeline.
    func pitch(title: String, line: String, pitch: String,
               relay: HermesRelayConfiguration) async {
        guard relay.isConfigured,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            state = try await HermesRelayClient(configuration: relay)
                .gamesConcept(title: title, line: line, pitch: pitch)
            isLive = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The cabinet reports a finished run. Persist the best locally, and forward
    /// it to the relay so the studio's record of its flagship stays current.
    func recordScore(_ score: Int, for game: StudioGame,
                     relay: HermesRelayConfiguration) {
        if score > localBest {
            UserDefaults.standard.set(score, forKey: Self.bestKey)
        }
        guard relay.isConfigured else { return }
        Task {
            _ = try? await HermesRelayClient(configuration: relay)
                .gamesScore(id: game.id, score: score)
        }
    }
}
