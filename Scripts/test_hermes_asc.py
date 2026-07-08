import importlib.util
import json
import sys
import tempfile
import time
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("hermes_asc.py")
SPEC = importlib.util.spec_from_file_location("hermes_asc", SCRIPT_PATH)
asc = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(asc)


def iso_days_ago(days: float) -> str:
    return datetime.fromtimestamp(time.time() - days * 86400,
                                  tz=timezone.utc).isoformat()


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.original = asc.ASC_CONFIG_PATH
        asc.ASC_CONFIG_PATH = self.root / "asc.json"
        asc._SUMMARY_CACHE.update(data=None, fetched=0.0)
        asc._JWT_CACHE.update(token="", issued=0.0)

    def tearDown(self):
        asc.ASC_CONFIG_PATH = self.original
        asc._SUMMARY_CACHE.update(data=None, fetched=0.0)
        asc._JWT_CACHE.update(token="", issued=0.0)
        self.tmp.cleanup()

    def write_config(self, **overrides):
        key = self.root / "AuthKey_TEST.p8"
        key.write_text("-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n")
        config = {"key_path": str(key), "key_id": "TESTKEY1", "issuer_id": "issuer-uuid"}
        config.update(overrides)
        asc.ASC_CONFIG_PATH.write_text(json.dumps(config))
        return config

    def test_missing_config_degrades_everywhere(self):
        self.assertIsNone(asc.asc_config())
        summary = asc.review_summary()
        self.assertFalse(summary["configured"])
        self.assertEqual(summary["apps"], [])
        self.assertIn("asc.json", summary["note"])
        self.assertEqual(asc.list_apps(), [])
        self.assertEqual(asc.recent_reviews("123"), [])
        self.assertEqual(asc.complaint_brief(), "")

    def test_garbage_config_is_none(self):
        asc.ASC_CONFIG_PATH.write_text("not json{{{")
        self.assertIsNone(asc.asc_config())

    def test_incomplete_config_is_none(self):
        asc.ASC_CONFIG_PATH.write_text('{"key_id": "X", "issuer_id": "Y"}')
        self.assertIsNone(asc.asc_config())

    def test_missing_key_file_is_none(self):
        self.write_config(key_path=str(self.root / "nope.p8"))
        self.assertIsNone(asc.asc_config())

    def test_valid_config_roundtrips(self):
        config = self.write_config()
        self.assertEqual(asc.asc_config(), config)

    def test_sales_summary_is_honest_about_being_skipped(self):
        summary = asc.sales_summary()
        self.assertFalse(summary["configured"])
        self.assertFalse(summary["available"])
        self.assertIn("not implemented", summary["note"])


class JwtTests(ConfigTests):
    def test_jwt_shape_for_asc(self):
        config = self.write_config()
        captured = {}

        def encode(payload, key, algorithm=None, headers=None):
            captured.update(payload=payload, key=key,
                            algorithm=algorithm, headers=headers)
            return "signed-token"

        fake_jwt = types.SimpleNamespace(encode=encode)
        with mock.patch.dict(sys.modules, {"jwt": fake_jwt}):
            token = asc.asc_jwt(config, now=1000.0)
        self.assertEqual(token, "signed-token")
        self.assertEqual(captured["algorithm"], "ES256")
        self.assertEqual(captured["headers"], {"kid": "TESTKEY1", "typ": "JWT"})
        self.assertEqual(captured["payload"]["iss"], "issuer-uuid")
        self.assertEqual(captured["payload"]["aud"], "appstoreconnect-v1")
        self.assertEqual(captured["payload"]["iat"], 1000)
        self.assertEqual(captured["payload"]["exp"], 1000 + 19 * 60)   # under Apple's 20-min cap
        self.assertIn("BEGIN PRIVATE KEY", captured["key"])

    def test_jwt_is_cached_within_window(self):
        config = self.write_config()
        calls = []
        fake_jwt = types.SimpleNamespace(
            encode=lambda *a, **k: calls.append(1) or "signed-token")
        with mock.patch.dict(sys.modules, {"jwt": fake_jwt}):
            asc.asc_jwt(config, now=1000.0)
            asc.asc_jwt(config, now=1000.0 + 60)
        self.assertEqual(len(calls), 1)

    def test_missing_pyjwt_degrades_to_none(self):
        config = self.write_config()
        # sys.modules[name] = None makes `import jwt` raise — the no-PyJWT world.
        with mock.patch.dict(sys.modules, {"jwt": None}):
            self.assertIsNone(asc.asc_jwt(config, now=1000.0))

    def test_summary_reports_unconfigured_when_signing_fails(self):
        self.write_config()
        with mock.patch.dict(sys.modules, {"jwt": None}):
            summary = asc.review_summary(force=True)
        self.assertFalse(summary["configured"])
        self.assertIn("pyjwt", summary["note"])


class RequestShapingTests(ConfigTests):
    def test_list_apps_maps_ids_and_names(self):
        self.write_config()
        payload = {"data": [{"id": "123", "attributes": {"name": "Tabula"}},
                            {"id": "456", "attributes": {}},
                            {"type": "junk-no-id"}]}
        with mock.patch.object(asc, "_asc_get", return_value=payload) as fetch:
            apps = asc.list_apps()
        self.assertEqual(apps, [{"id": "123", "name": "Tabula"},
                                {"id": "456", "name": ""}])
        self.assertEqual(fetch.call_args[0][0], "/v1/apps?limit=50")

    def test_recent_reviews_filters_by_window_and_maps_fields(self):
        self.write_config()
        payload = {"data": [
            {"id": "r1", "attributes": {"rating": 1, "title": "Sync broken",
                                        "body": "lost my data",
                                        "createdDate": iso_days_ago(1)}},
            {"id": "r2", "attributes": {"rating": 5, "title": "Great",
                                        "body": "love it",
                                        "createdDate": iso_days_ago(30)}},
            {"id": "r3", "attributes": {"rating": 2, "title": None, "body": None,
                                        "createdDate": "not-a-date"}},
        ]}
        with mock.patch.object(asc, "_asc_get", return_value=payload) as fetch:
            reviews = asc.recent_reviews("123", since_days=7)
        self.assertEqual(reviews, [{"rating": 1, "title": "Sync broken",
                                    "body": "lost my data",
                                    "date": payload["data"][0]["attributes"]["createdDate"]}])
        self.assertIn("/v1/apps/123/customerReviews", fetch.call_args[0][0])
        self.assertIn("sort=-createdDate", fetch.call_args[0][0])

    def test_review_summary_shape_and_hour_cache(self):
        self.write_config()
        with mock.patch.object(asc, "asc_jwt", return_value="signed"), \
                mock.patch.object(asc, "list_apps",
                                  return_value=[{"id": "123", "name": "Tabula"}]) as apps, \
                mock.patch.object(asc, "recent_reviews",
                                  return_value=[{"rating": 2, "title": "Meh",
                                                 "body": "crashes", "date": "d"}]):
            first = asc.review_summary(force=True)
            second = asc.review_summary()
        self.assertTrue(first["configured"])
        self.assertEqual(first["apps"], [{"id": "123", "name": "Tabula",
                                          "recent_reviews": [{"rating": 2, "title": "Meh",
                                                              "body": "crashes", "date": "d"}]}])
        self.assertIs(second, first)                 # served from the 1h cache
        self.assertEqual(apps.call_count, 1)

    def test_fetch_failure_is_empty_never_raises(self):
        self.write_config()
        with mock.patch.object(asc, "asc_jwt", return_value="signed"), \
                mock.patch.object(asc, "_asc_get", return_value=None):
            self.assertEqual(asc.list_apps(), [])
            self.assertEqual(asc.recent_reviews("123"), [])

    def test_complaint_brief_keeps_only_one_to_three_stars(self):
        summary = {"configured": True, "apps": [
            {"id": "1", "name": "Tabula", "recent_reviews": [
                {"rating": 1, "title": "Sync broken", "body": "lost my data", "date": "d"},
                {"rating": 5, "title": "Great", "body": "love it", "date": "d"},
                {"rating": 3, "title": "Meh", "body": "slow on iPad", "date": "d"},
                {"rating": None, "title": "?", "body": "?", "date": "d"},
            ]}]}
        brief = asc.complaint_brief(summary)
        self.assertIn("Sync broken", brief)
        self.assertIn("slow on iPad", brief)
        self.assertNotIn("Great", brief)

    def test_complaint_brief_empty_when_unconfigured_or_happy(self):
        self.assertEqual(asc.complaint_brief({"configured": False, "apps": []}), "")
        self.assertEqual(asc.complaint_brief(
            {"configured": True, "apps": [{"id": "1", "name": "T",
                                           "recent_reviews": [{"rating": 5, "title": "A",
                                                               "body": "B", "date": "d"}]}]}), "")

    def test_review_ts_handles_apple_offsets_and_garbage(self):
        self.assertGreater(asc._review_ts("2026-07-01T10:32:01-07:00"), 0)
        self.assertEqual(asc._review_ts("not-a-date"), 0.0)
        self.assertEqual(asc._review_ts(None), 0.0)


if __name__ == "__main__":
    unittest.main()
