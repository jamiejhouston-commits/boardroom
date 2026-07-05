import XCTest
@testable import HermesMobile

/// The Games Studio models: the bundled flagship, JSON decode from the relay,
/// and the derived helpers the room renders from.
final class GamesStudioModelsTests: XCTestCase {

    func testFlagshipIsRealShippedAndPlayable() {
        let game = StudioGame.skylineStack
        XCTAssertTrue(game.isShipped)
        XCTAssertTrue(game.isPlayable)
        XCTAssertEqual(game.runtime, "SkylineStack.html")
        XCTAssertTrue(game.funGate.isApproved)
        XCTAssertEqual(game.distribution["itch"], "live")
        XCTAssertFalse(game.pillars.isEmpty)
        XCTAssertEqual(game.progress, 1.0)
    }

    func testFlagshipStateAlwaysHasAPlayableGame() {
        let state = GamesStudioState.flagship
        XCTAssertNotNil(state.currentGame)
        XCTAssertTrue(state.games.contains { $0.isPlayable })
    }

    func testAverageFunAggregates() {
        let game = StudioGame.skylineStack   // 9, 8, 9
        XCTAssertEqual(game.averageFun, 8.7, accuracy: 0.05)
    }

    func testProgressAndStageLabels() {
        func game(_ stage: String) -> StudioGame {
            var g = StudioGame.skylineStack; g.stage = stage; return g
        }
        XCTAssertEqual(game("concept").progress, 0.12, accuracy: 0.001)
        XCTAssertGreaterThan(game("distribution").progress, game("playtest").progress)
        XCTAssertEqual(game("shelved").progress, 0.0, accuracy: 0.001)
        XCTAssertEqual(game("fun_gate").stageLabel, "Fun Gate")
    }

    func testDecodeFromRelayJSON() throws {
        // Snake-cased payload exactly as the relay emits it.
        let json = """
        {
          "enabled": true,
          "games": [{
            "id": "abc123",
            "title": "Neon Drift",
            "line": "hyper-casual",
            "pitch": "dodge and drift",
            "stage": "fun_gate",
            "pillars": ["one-tap", "rising speed"],
            "build_notes": "canvas racer",
            "runtime": "index.html",
            "playtests": [{"tester": "Pixel", "rating": 8, "reaction": "snappy"}],
            "fun_gate": {"verdict": "APPROVED", "reasons": ["fun fast"]},
            "distribution": {"itch": "live", "reddit": "submitted", "portals": "planned"},
            "score": 42,
            "created": "2026-07-05T10:00:00"
          }],
          "events": [{"text": "shipped: Neon Drift", "ts": 1.0}],
          "last_tick": 123.0
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let state = try decoder.decode(GamesStudioState.self, from: json)
        XCTAssertTrue(state.enabled)
        let game = try XCTUnwrap(state.currentGame)
        XCTAssertEqual(game.title, "Neon Drift")
        XCTAssertEqual(game.buildNotes, "canvas racer")
        XCTAssertTrue(game.funGate.isApproved)
        XCTAssertEqual(game.score, 42)
        XCTAssertEqual(game.distributionChannels.count, 3)
    }

    func testChannelStatusMapping() {
        XCTAssertEqual(ChannelStatus("live"), .live)
        XCTAssertEqual(ChannelStatus("garbage"), .planned)
        XCTAssertEqual(ChannelStatus.submitted.label, "Submitted")
    }
}
