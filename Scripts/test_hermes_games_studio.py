import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("hermes_games_studio.py")
SPEC = importlib.util.spec_from_file_location("hermes_games_studio", SCRIPT_PATH)
studio = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(studio)


class StateStoreTests(unittest.TestCase):
    def test_new_state_defaults(self):
        state = studio.new_studio_state()
        self.assertFalse(state["enabled"])
        self.assertEqual(state["games"], [])
        self.assertEqual(state["events"], [])

    def test_new_game_shape(self):
        game = studio.new_game("Bloom Sort", "daily-puzzle")
        self.assertEqual(game["stage"], "concept")
        self.assertEqual(game["line"], "daily-puzzle")
        self.assertEqual(game["calls_used"], 0)
        self.assertEqual(game["fun_gate"], {"verdict": "", "reasons": []})
        self.assertEqual(game["distribution"],
                         {"itch": "planned", "reddit": "planned", "portals": "planned"})
        self.assertTrue(game["id"])

    def test_unknown_line_defaults_to_hyper_casual(self):
        self.assertEqual(studio.new_game("X", "roguelike")["line"], "hyper-casual")

    def test_store_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = studio.StudioStore(Path(tmp) / "studio.json")
            state = studio.new_studio_state()
            state["enabled"] = True
            studio.seed_concept(state, "Neon Drift", "hyper-casual")
            store.save(state)
            loaded = store.load()
            self.assertTrue(loaded["enabled"])
            self.assertTrue(any(g["title"] == "Neon Drift" for g in loaded["games"]))

    def test_store_load_missing_file_seeds_flagship(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = studio.StudioStore(Path(tmp) / "nope.json")
            loaded = store.load()
            self.assertTrue(any(g["runtime"] == studio.FLAGSHIP_RUNTIME
                                for g in loaded["games"]))


class ParserTests(unittest.TestCase):
    def test_parse_pillars_strips_bullets_and_headers(self):
        text = ("Design pillars:\n- One-tap core loop\n2. Rising speed only\n"
                "* Instant restart\n\n")
        pillars = studio.parse_pillars(text)
        self.assertEqual(pillars,
                         ["One-tap core loop", "Rising speed only", "Instant restart"])

    def test_parse_pillars_caps_at_five(self):
        text = "\n".join(f"- pillar {i}" for i in range(9))
        self.assertEqual(len(studio.parse_pillars(text)), 5)

    def test_parse_playtest_reads_rating(self):
        result = studio.parse_playtest("Snappy and addictive. Rating: 8/10")
        self.assertEqual(result["rating"], 8)
        self.assertIn("Snappy", result["reaction"])

    def test_parse_playtest_clamps_and_defaults(self):
        self.assertEqual(studio.parse_playtest("meh")["rating"], 5)
        self.assertEqual(studio.parse_playtest("11/10 amazing")["rating"], 10)
        self.assertEqual(studio.parse_playtest("fun: 9")["rating"], 9)

    def test_playtest_scores_average(self):
        game = {"playtests": [{"rating": 8}, {"rating": 9}, {"rating": 7}]}
        avg, count = studio.playtest_scores(game)
        self.assertEqual((avg, count), (8.0, 3))
        self.assertEqual(studio.playtest_scores({"playtests": []}), (0.0, 0))

    def test_fun_gate_passed_later_verdict_wins(self):
        self.assertTrue(studio.fun_gate_passed("reasons…\nGATE: APPROVED"))
        self.assertFalse(studio.fun_gate_passed("GATE: REJECTED\nboring"))
        # A reconsidered verdict: the final marker is what counts.
        self.assertTrue(studio.fun_gate_passed("GATE: REJECTED\n…\nGATE: APPROVED"))
        self.assertFalse(studio.fun_gate_passed("no verdict here"))

    def test_parse_fun_reasons(self):
        text = "- Fun instantly\n- Combo hook lands\nGATE: APPROVED"
        reasons = studio.parse_fun_reasons(text)
        self.assertEqual(reasons, ["Fun instantly", "Combo hook lands"])

    def test_parse_distribution_maps_channels(self):
        text = "itch: live and posted. reddit: submitted to r/WebGames. portals: planned."
        dist = studio.parse_distribution(text)
        self.assertEqual(dist, {"itch": "live", "reddit": "submitted", "portals": "planned"})

    def test_parse_distribution_defaults_on_garbage(self):
        dist = studio.parse_distribution("nothing useful")
        self.assertEqual(set(dist.keys()), {"itch", "reddit", "portals"})
        for status in dist.values():
            self.assertIn(status, studio.CHANNEL_STATES)


class ChargedRunnerTests(unittest.TestCase):
    def test_counts_and_raises_over_budget(self):
        game = studio.new_game("X", "hyper-casual")
        runner = studio.make_charged_runner(game, budget=2, runner=lambda r, p: "ok")
        self.assertEqual(runner("builder", "hi"), "ok")
        runner("builder", "again")
        with self.assertRaises(studio.BudgetExceeded):
            runner("builder", "third")
        self.assertEqual(game["calls_used"], 2)


class PipelineTests(unittest.TestCase):
    """Drive a game through the whole machine with a scripted runner."""

    def make_state(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Neon Drift", "hyper-casual", "dodge and drift")
        return state, game

    def advance(self, state, game, runner):
        studio.advance_game(state, game, studio.make_charged_runner(game, 40, runner))

    def test_full_pipeline_ships_a_fun_game(self):
        state, game = self.make_state()

        def runner(role, prompt):
            if role == "game_designer" and "FUN GATE" in prompt:
                return "- Fun instantly\n- Great feedback\nGATE: APPROVED"
            if role == "game_designer" and "DESIGN PILLARS" in prompt:
                return "- One-tap loop\n- Rising speed\n- Instant restart"
            if role == "playtester":
                return "Loved it, one more go. Rating: 9/10"
            if role == "distributor":
                return "itch: live. reddit: submitted. portals: planned."
            return "sharpened concept"

        stages = []
        for _ in range(len(studio.STAGE_ORDER) + 1):
            if game["stage"] in studio.TERMINAL_STAGES:
                break
            self.advance(state, game, runner)
            stages.append(game["stage"])

        self.assertEqual(game["stage"], "shipped")
        self.assertEqual(game["fun_gate"]["verdict"], "APPROVED")
        self.assertEqual(len(game["playtests"]), len(studio.PLAYTEST_PANEL))
        self.assertEqual(game["distribution"]["itch"], "live")
        self.assertTrue(game["pillars"])
        # Stages progressed monotonically through the machine.
        self.assertEqual(stages,
                         ["design", "build", "playtest", "fun_gate",
                          "distribution", "shipped"])

    def test_fun_gate_rejection_loops_back_to_design(self):
        state, game = self.make_state()

        def runner(role, prompt):
            if role == "game_designer" and "FUN GATE" in prompt:
                return "- Boring after 5 seconds\n- No hook\nGATE: REJECTED"
            if role == "game_designer" and "DESIGN PILLARS" in prompt:
                return "- loop\n- feedback"
            if role == "playtester":
                return "Kinda dull. Rating: 3/10"
            return "concept"

        # concept→design→build→playtest→fun_gate(reject)→design
        for _ in range(5):
            self.advance(state, game, runner)
        self.assertEqual(game["fun_gate"]["verdict"], "REJECTED")
        self.assertEqual(game["stage"], "design")
        self.assertEqual(game["iteration"], 1)
        self.assertEqual(game["rejections"], 1)
        self.assertTrue(game["fun_gate"]["reasons"])

    def test_repeated_rejection_shelves_the_game(self):
        state, game = self.make_state()

        def runner(role, prompt):
            if "FUN GATE" in prompt:
                return "GATE: REJECTED"
            if role == "playtester":
                return "no. Rating: 2/10"
            return "x"

        # Loop the reject cycle until it shelves.
        for _ in range(40):
            if game["stage"] in studio.TERMINAL_STAGES:
                break
            self.advance(state, game, runner)
        self.assertEqual(game["stage"], "shelved")
        self.assertGreaterEqual(game["rejections"], studio.MAX_REJECTIONS)

    def test_build_writes_file_when_artifacts_root_given(self):
        state, game = self.make_state()
        game["stage"] = "build"
        game["pillars"] = ["loop"]
        with tempfile.TemporaryDirectory() as tmp:
            self.advance_with_root(state, game, tmp,
                                   lambda r, p: "built it, entry index.html")
            # The build turn created the game's working directory.
            self.assertTrue(any(Path(tmp).iterdir()))
        self.assertEqual(game["stage"], "playtest")
        self.assertTrue(game["runtime"])

    def advance_with_root(self, state, game, root, runner):
        studio.advance_game(state, game,
                            studio.make_charged_runner(game, 40, runner), Path(root))


class TickTests(unittest.TestCase):
    def test_tick_noop_when_disabled(self):
        state = studio.new_studio_state()
        studio.seed_concept(state, "X", "hyper-casual")
        self.assertEqual(studio.tick(state, lambda r, p: "x", now=1000), [])

    def test_tick_advances_when_enabled(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "X", "hyper-casual")
        events = studio.tick(state, lambda r, p: "sharper", now=1000)
        self.assertTrue(events)
        self.assertEqual(game["stage"], "design")
        self.assertEqual(state["last_tick"], 1000)

    def test_tick_skips_shipped_games(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        flagship = studio.seed_flagship(state)   # already shipped
        events = studio.tick(state, lambda r, p: "x", now=1000)
        self.assertEqual(flagship["stage"], "shipped")
        self.assertEqual(events, [])


class SeedTests(unittest.TestCase):
    def test_seed_flagship_is_idempotent(self):
        state = studio.new_studio_state()
        studio.seed_flagship(state)
        studio.seed_flagship(state)
        flagships = [g for g in state["games"] if g["runtime"] == studio.FLAGSHIP_RUNTIME]
        self.assertEqual(len(flagships), 1)

    def test_flagship_is_shipped_and_approved(self):
        state = studio.new_studio_state()
        game = studio.seed_flagship(state)
        self.assertEqual(game["stage"], "shipped")
        self.assertEqual(game["fun_gate"]["verdict"], "APPROVED")
        self.assertEqual(game["distribution"]["itch"], "live")
        self.assertTrue(game["pillars"])
        self.assertEqual(len(game["playtests"]), 3)


if __name__ == "__main__":
    unittest.main()
