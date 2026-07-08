import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

    def test_parse_playtest_ignores_numbers_in_the_reaction(self):
        # A stray number in the prose must NOT override the stated rating.
        self.assertEqual(
            studio.parse_playtest("Died on level 4 instantly. Rating: 8/10")["rating"], 8)
        self.assertEqual(
            studio.parse_playtest("I played for 3 minutes and loved it. Rating: 9/10")["rating"], 9)
        self.assertEqual(
            studio.parse_playtest("Got 5 combos in a row! Rating: 10/10")["rating"], 10)
        # A bare unlabeled number with no /10 stays at the default.
        self.assertEqual(studio.parse_playtest("reminded me of the 90s")["rating"], 5)

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
        # An unverified "live" claim is honestly downgraded to planned.
        dist = studio.parse_distribution(text)
        self.assertEqual(dist, {"itch": "planned", "reddit": "submitted", "portals": "planned"})
        # A VERIFIED publish lets the live claim stand.
        dist = studio.parse_distribution(text, verified=True)
        self.assertEqual(dist, {"itch": "live", "reddit": "submitted", "portals": "planned"})

    def test_parse_distribution_defaults_to_planned(self):
        dist = studio.parse_distribution("nothing useful")
        self.assertEqual(dist, {"itch": "planned", "reddit": "planned", "portals": "planned"})

    def test_parse_distribution_asset_channels(self):
        text = ("itch: live. Roblox Creator Store: submitted for review. "
                "Unity Asset Store: planned for next week.")
        dist = studio.parse_distribution(text, asset=True)
        self.assertEqual(dist, {"itch": "planned", "roblox": "submitted", "unity": "planned"})


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
        # No verified publish happened, so the "live" claim was not believed.
        self.assertEqual(game["distribution"]["itch"], "planned")
        self.assertFalse(game["distribution_verified"])
        self.assertTrue(game["pillars"])
        # Stages progressed monotonically through the machine.
        self.assertEqual(stages,
                         ["design", "build", "playtest", "fun_gate",
                          "distribution", "shipped"])

    def test_full_pipeline_ships_an_asset_pack(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Voxel Dungeon Props", "asset-3d",
                                   "50 modular dungeon pieces")
        self.assertTrue(studio.is_asset(game))

        def runner(role, prompt):
            if role == "game_designer" and "QUALITY GATE" in prompt:
                return "- Consistent style\n- Store-ready formats\nGATE: APPROVED"
            if role == "game_designer" and "PACK PILLARS" in prompt:
                return "- Low-poly stylized, one palette\n- 50 pieces\n- glTF+FBX+OBJ"
            if role == "artist":
                self.assertIn("blender", prompt.lower())   # the toolkit rode along
                self.assertIn("roblox", prompt.lower())
                return "Built 50 meshes, exported glTF/FBX/OBJ + previews."
            if role == "playtester":
                return "Would buy — drops straight into Unity. Rating: 9/10"
            if role == "distributor":
                return "itch: live. Roblox Creator Store: submitted. Unity: planned."
            return "sharpened pack concept"

        for _ in range(len(studio.STAGE_ORDER) + 1):
            if game["stage"] in studio.TERMINAL_STAGES:
                break
            self.advance(state, game, runner)

        self.assertEqual(game["stage"], "shipped")
        self.assertEqual(game["fun_gate"]["verdict"], "APPROVED")
        self.assertEqual(game["runtime"], "")   # packs never enter the cabinet
        self.assertEqual(set(game["distribution"].keys()), {"itch", "roblox", "unity"})
        self.assertEqual(game["distribution"]["roblox"], "submitted")
        self.assertEqual(game["distribution"]["itch"], "planned")   # unverified

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
            outdir = Path(tmp) / studio._game_dirname(game)

            def runner(role, prompt):
                # The builder actually writes the game file — so verification
                # passes and the stage advances.
                (outdir / "index.html").write_text("<canvas></canvas>")
                return "built it, entry index.html"

            self.advance_with_root(state, game, tmp, runner)
            # The build turn created the game's working directory + file.
            self.assertTrue((outdir / "index.html").exists())
        self.assertEqual(game["stage"], "playtest")
        self.assertTrue(game["runtime"])

    def test_build_without_file_does_not_advance(self):
        state, game = self.make_state()
        game["stage"] = "build"
        game["pillars"] = ["loop"]
        with tempfile.TemporaryDirectory() as tmp:
            # The builder only TALKS about a build — nothing hits the disk.
            self.advance_with_root(state, game, tmp, lambda r, p: "built it, honest")
        self.assertEqual(game["stage"], "build", "no file → no advance")
        self.assertEqual(game["runtime"], "")
        self.assertTrue(any("produced no game file" in e["text"]
                            for e in state["events"]))

    def test_build_with_empty_file_does_not_advance(self):
        state, game = self.make_state()
        game["stage"] = "build"
        game["pillars"] = ["loop"]
        with tempfile.TemporaryDirectory() as tmp:
            outdir = Path(tmp) / studio._game_dirname(game)

            def runner(role, prompt):
                (outdir / "index.html").touch()   # zero bytes is not a game
                return "built it"

            self.advance_with_root(state, game, tmp, runner)
        self.assertEqual(game["stage"], "build")

    def test_asset_build_without_files_does_not_advance(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Voxel Props", "asset-3d")
        game["stage"] = "build"
        game["pillars"] = ["50 pieces"]
        with tempfile.TemporaryDirectory() as tmp:
            self.advance_with_root(state, game, tmp, lambda r, p: "made 50 meshes")
        self.assertEqual(game["stage"], "build")
        self.assertTrue(any("produced no pack files" in e["text"]
                            for e in state["events"]))

    def test_playtest_prompt_contains_the_real_game_code(self):
        state, game = self.make_state()
        game["stage"] = "playtest"
        game["pillars"] = ["loop"]
        game["runtime"] = "index.html"
        prompts = []

        def runner(role, prompt):
            prompts.append(prompt)
            return "Tight controls, clean game over. Rating: 8/10"

        with tempfile.TemporaryDirectory() as tmp:
            outdir = Path(tmp) / studio._game_dirname(game)
            outdir.mkdir(parents=True)
            (outdir / "index.html").write_text("<canvas id='neon-drift-game'>")
            self.advance_with_root(state, game, tmp, runner)

        self.assertEqual(len(prompts), len(studio.PLAYTEST_PANEL))
        for prompt in prompts:
            self.assertIn("neon-drift-game", prompt)
            self.assertIn("ACTUAL GAME CODE", prompt)
        # The ratings parser still reads the replies unchanged.
        self.assertEqual(game["playtests"][0]["rating"], 8)

    def test_playtest_code_is_capped_and_marked_truncated(self):
        state, game = self.make_state()
        game["stage"] = "playtest"
        prompts = []

        def runner(role, prompt):
            prompts.append(prompt)
            return "ok. Rating: 5/10"

        with tempfile.TemporaryDirectory() as tmp:
            outdir = Path(tmp) / studio._game_dirname(game)
            outdir.mkdir(parents=True)
            (outdir / "index.html").write_text("x" * (studio.PLAYTEST_CODE_CAP + 500))
            self.advance_with_root(state, game, tmp, runner)

        self.assertIn("truncated", prompts[0])
        self.assertLess(len(prompts[0]), studio.PLAYTEST_CODE_CAP + 2_000)

    def test_rejection_feedback_reaches_next_design_and_build(self):
        state, game = self.make_state()
        game["fun_gate"] = {"verdict": "REJECTED",
                            "reasons": ["No hook in ten seconds"]}
        game["playtests"] = [{"tester": "Pixel", "rating": 3,
                              "reaction": "Kinda dull honestly."}]
        game["iteration"] = 1
        prompts = {}

        def runner(role, prompt):
            prompts[game["stage"]] = prompt
            return "- loop\n- feedback"

        game["stage"] = "design"
        self.advance(state, game, runner)          # design turn
        self.advance(state, game, runner)          # build turn (no artifacts root)
        for stage in ("design", "build"):
            self.assertIn("PREVIOUS ITERATION FEEDBACK", prompts[stage])
            self.assertIn("No hook in ten seconds", prompts[stage])
            self.assertIn("Kinda dull honestly.", prompts[stage])

    def test_no_feedback_block_on_first_pass(self):
        state, game = self.make_state()
        game["stage"] = "design"
        prompts = []
        self.advance(state, game, lambda r, p: prompts.append(p) or "- loop")
        self.assertNotIn("PREVIOUS ITERATION FEEDBACK", prompts[0])

    def advance_with_root(self, state, game, root, runner):
        studio.advance_game(state, game,
                            studio.make_charged_runner(game, 40, runner), Path(root))


class DistributionHonestyTests(unittest.TestCase):
    def _shipped_setup(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Neon Drift", "hyper-casual")
        game["stage"] = "distribution"
        game["playtests"] = [{"tester": "Pixel", "rating": 9, "reaction": "yes"}]
        return state, game

    def test_butler_missing_leaves_planned_with_honest_event(self):
        state, game = self._shipped_setup()
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(studio.shutil, "which", return_value=None):
            studio.advance_game(state, game,
                                studio.make_charged_runner(
                                    game, 40, lambda r, p: "itch: live!"),
                                Path(tmp))
        self.assertEqual(game["stage"], "shipped")
        self.assertEqual(game["distribution"]["itch"], "planned")
        self.assertFalse(game["distribution_verified"])
        self.assertTrue(any("butler/itch not configured" in e["text"]
                            for e in state["events"]))

    def test_verified_publish_marks_itch_live_with_url(self):
        state, game = self._shipped_setup()
        url = "https://andrew.itch.io/neon-drift"
        with mock.patch.object(studio, "publish_itch", return_value=url):
            studio.advance_game(state, game,
                                studio.make_charged_runner(
                                    game, 40, lambda r, p: "itch: live"),
                                Path("/tmp"))
        self.assertEqual(game["distribution"]["itch"], "live")
        self.assertTrue(game["distribution_verified"])
        self.assertEqual(game["itch_url"], url)

    def test_publish_itch_returns_none_without_butler(self):
        game = studio.new_game("X", "hyper-casual")
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(studio.shutil, "which", return_value=None):
            self.assertIsNone(studio.publish_itch(game, Path(tmp)))
        self.assertIsNone(studio.publish_itch(game, None))


class PausedTests(unittest.TestCase):
    def test_budget_exceeded_pauses_instead_of_shelving(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Money Pit", "hyper-casual")
        game["calls_used"] = studio.DEFAULT_BUDGET   # already exhausted
        events = studio.tick(state, lambda r, p: "x", now=1000)
        self.assertEqual(game["stage"], "paused")
        self.assertIn("paused", events[0])
        self.assertIn("budget", game["paused_note"])
        self.assertNotIn("paused", studio.TERMINAL_STAGES)   # NOT terminal

    def test_paused_game_is_skipped_by_tick(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Money Pit", "hyper-casual")
        game["stage"] = "paused"
        calls = []
        events = studio.tick(state, lambda r, p: calls.append(r) or "x", now=1000)
        self.assertEqual(events, [])
        self.assertEqual(calls, [])
        self.assertEqual(game["stage"], "paused")

    def test_pause_stores_the_pre_pause_stage(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Money Pit", "hyper-casual")
        game["stage"] = "playtest"
        game["calls_used"] = studio.DEFAULT_BUDGET
        studio.tick(state, lambda r, p: "x", now=1000)
        self.assertEqual(game["stage"], "paused")
        self.assertEqual(game["paused_from"], "playtest")

    def test_resume_restores_stage_and_tops_up_budget(self):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Money Pit", "hyper-casual")
        game.update({"stage": "paused", "paused_from": "playtest",
                     "paused_note": "budget exhausted",
                     "calls_used": studio.DEFAULT_BUDGET})
        resumed = studio.resume_game(state, game["id"])
        self.assertIs(resumed, game)
        self.assertEqual(game["stage"], "playtest")
        self.assertEqual(game["calls_used"],
                         studio.DEFAULT_BUDGET - studio.RESUME_TOP_UP_CALLS)
        self.assertNotIn("paused_from", game)
        self.assertNotIn("paused_note", game)
        self.assertTrue(any("resumed" in e["text"] for e in state["events"]))
        # The top-up means the next tick actually spends turns again.
        events = studio.tick(state, lambda r, p: "fun. Rating: 8/10", now=1000)
        self.assertTrue(events)
        self.assertEqual(game["stage"], "fun_gate")

    def test_resume_defaults_to_build_for_legacy_pauses(self):
        state = studio.new_studio_state()
        game = studio.seed_concept(state, "Old Pause", "hyper-casual")
        game["stage"] = "paused"          # no paused_from recorded pre-upgrade
        studio.resume_game(state, game["id"])
        self.assertEqual(game["stage"], "build")

    def test_resume_top_up_never_goes_negative(self):
        state = studio.new_studio_state()
        game = studio.seed_concept(state, "Cheap Pause", "hyper-casual")
        game.update({"stage": "paused", "paused_from": "design", "calls_used": 3})
        studio.resume_game(state, game["id"])
        self.assertEqual(game["calls_used"], 0)

    def test_resume_unknown_and_not_paused_raise(self):
        state = studio.new_studio_state()
        game = studio.seed_concept(state, "Running Fine", "hyper-casual")
        with self.assertRaises(KeyError):
            studio.resume_game(state, "nope")
        with self.assertRaises(ValueError):
            studio.resume_game(state, game["id"])   # concept, not paused


class MergeTickTests(unittest.TestCase):
    """The lost-update guard: owner actions during a long tick must survive."""

    def _state_with_game(self, stage="playtest"):
        state = studio.new_studio_state()
        state["enabled"] = True
        game = studio.seed_concept(state, "Neon Drift", "hyper-casual")
        game["stage"] = stage
        return state, game

    def test_halt_during_tick_is_preserved(self):
        before_state, game = self._state_with_game()
        before = json.loads(json.dumps(before_state))
        # The tick advances the game (its in-memory copy still enabled=True).
        ticked = json.loads(json.dumps(before_state))
        ticked["games"][0]["stage"] = "fun_gate"
        # Meanwhile the owner halted the studio on disk.
        current = json.loads(json.dumps(before_state))
        current["enabled"] = False
        merged = studio.merge_tick_results(current, ticked, before)
        self.assertFalse(merged["enabled"], "halt must survive the tick's stale write")
        self.assertEqual(merged["games"][0]["stage"], "fun_gate", "tick progress still lands")

    def test_score_recorded_during_tick_is_preserved(self):
        before_state, _ = self._state_with_game()
        before = json.loads(json.dumps(before_state))
        ticked = json.loads(json.dumps(before_state))
        ticked["games"][0]["stage"] = "fun_gate"
        current = json.loads(json.dumps(before_state))
        current["games"][0]["score"] = 99          # owner set a high score mid-tick
        merged = studio.merge_tick_results(current, ticked, before)
        self.assertEqual(merged["games"][0]["score"], 99)
        self.assertEqual(merged["games"][0]["stage"], "fun_gate")

    def test_concept_pitched_during_tick_is_preserved(self):
        before_state, _ = self._state_with_game()
        before = json.loads(json.dumps(before_state))
        ticked = json.loads(json.dumps(before_state))
        ticked["games"][0]["stage"] = "fun_gate"
        current = json.loads(json.dumps(before_state))
        studio.seed_concept(current, "Late Idea", "daily-puzzle")   # owner pitched mid-tick
        merged = studio.merge_tick_results(current, ticked, before)
        titles = [g["title"] for g in merged["games"]]
        self.assertIn("Late Idea", titles)
        self.assertIn("Neon Drift", titles)


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
