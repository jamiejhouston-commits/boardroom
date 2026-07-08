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

    /// Pre-per-game-key flagship best — migrated on first read.
    private static let legacyBestKey = "gamesStudio.best.SkylineStack"

    private static func bestKey(for gameID: String) -> String {
        "gamesStudio.best.\(gameID)"
    }

    var currentGame: StudioGame? { state.currentGame }

    /// The owner's best score for one game (device-side source of truth for
    /// offline play; mirrors the relay copy when connected).
    func localBest(for game: StudioGame) -> Int {
        let best = UserDefaults.standard.integer(forKey: Self.bestKey(for: game.id))
        if best == 0, game.id == StudioGame.skylineStack.id {
            return UserDefaults.standard.integer(forKey: Self.legacyBestKey)
        }
        return best
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
        guard relay.isConfigured else {
            errorMessage = "Connect your Mac relay first — the studio runs on the Mac."
            return
        }
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
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard relay.isConfigured else {
            errorMessage = "Connect your Mac relay first — the pitch can't reach the studio."
            return
        }
        do {
            state = try await HermesRelayClient(configuration: relay)
                .gamesConcept(title: title, line: line, pitch: pitch)
            isLive = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resume a paused game — the studio picks it back up with a fresh budget.
    func resume(id: String, relay: HermesRelayConfiguration) async {
        guard relay.isConfigured else {
            errorMessage = "Connect your Mac relay first — the studio runs on the Mac."
            return
        }
        do {
            state = try await HermesRelayClient(configuration: relay).gamesResume(id: id)
            isLive = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The cabinet reports a finished run. Persist the best locally, and forward
    /// it to the relay so the studio's record stays current.
    func recordScore(_ score: Int, for game: StudioGame,
                     relay: HermesRelayConfiguration) {
        if score > localBest(for: game) {
            UserDefaults.standard.set(score, forKey: Self.bestKey(for: game.id))
        }
        guard relay.isConfigured else { return }
        Task {
            _ = try? await HermesRelayClient(configuration: relay)
                .gamesScore(id: game.id, score: score)
        }
    }
}
