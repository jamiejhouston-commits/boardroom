"""App Store Connect for the Boardroom: shipped-app reviews become roadmap.

Configure once with ~/.hermes/asc.json:
    {"key_path": "~/keys/AuthKey_XXXX.p8", "key_id": "XXXX", "issuer_id": "..."}

Unconfigured (or broken key / missing PyJWT) => everything degrades to
configured:false with an honest note — never a crash, never faked data.
The relay's venv ships PyJWT + cryptography (same ES256 path APNs uses).
"""

from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path

ASC_CONFIG_PATH = Path.home() / ".hermes" / "asc.json"
ASC_API = "https://api.appstoreconnect.apple.com"
SUMMARY_CACHE_SECONDS = 3600          # respect ASC rate limits: ~1 fetch/hour
REVIEW_SINCE_DAYS = 7

_JWT_CACHE: dict = {"token": "", "issued": 0.0}
_SUMMARY_CACHE: dict = {"data": None, "fetched": 0.0}


def asc_config() -> dict | None:
    """The owner's ASC key config, or None when absent/incomplete/unreadable."""
    try:
        data = json.loads(ASC_CONFIG_PATH.read_text())
        if (all(data.get(k) for k in ("key_path", "key_id", "issuer_id"))
                and Path(data["key_path"]).expanduser().is_file()):
            return data
    except (OSError, json.JSONDecodeError, ValueError, TypeError):
        pass
    return None


def asc_jwt(config: dict, now: float | None = None) -> str | None:
    """Signed ES256 provider token for the ASC API, cached ~15 min (Apple caps
    tokens at 20). None + honest log when PyJWT/cryptography is unavailable."""
    now = now if now is not None else time.time()
    if _JWT_CACHE["token"] and now - _JWT_CACHE["issued"] < 15 * 60:
        return _JWT_CACHE["token"]
    try:
        import jwt as pyjwt  # PyJWT + cryptography ship in the hermes venv
        key = Path(config["key_path"]).expanduser().read_text()
        token = pyjwt.encode(
            {"iss": config["issuer_id"], "iat": int(now),
             "exp": int(now) + 19 * 60, "aud": "appstoreconnect-v1"},
            key, algorithm="ES256",
            headers={"kid": config["key_id"], "typ": "JWT"})
        _JWT_CACHE.update(token=token, issued=now)
        return token
    except Exception as error:  # noqa: BLE001 — reviews are telemetry, never fatal
        print(f"asc - jwt failed ({type(error).__name__}): {error} "
              "(install pyjwt+cryptography in the relay venv)", flush=True)
        return None


def _asc_get(path: str, config: dict) -> dict | None:
    """One authenticated GET against the ASC API. None on any failure (logged)."""
    bearer = asc_jwt(config)
    if not bearer:
        return None
    import urllib.request
    request = urllib.request.Request(
        f"{ASC_API}{path}", headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode())
    except Exception as error:  # noqa: BLE001
        print(f"asc - fetch failed {path}: {error}", flush=True)
        return None


def _review_ts(created: str) -> float:
    """ASC createdDate ('2026-07-01T10:32:01-07:00') → epoch; 0.0 if unparseable."""
    try:
        return datetime.fromisoformat(created).timestamp()
    except (ValueError, TypeError):
        return 0.0


def list_apps() -> list[dict]:
    """[{id, name}] for every app on the account; [] when unconfigured/failed."""
    config = asc_config()
    if config is None:
        return []
    payload = _asc_get("/v1/apps?limit=50", config) or {}
    return [{"id": item["id"],
             "name": (item.get("attributes") or {}).get("name", "")}
            for item in payload.get("data", [])
            if isinstance(item, dict) and item.get("id")]


def recent_reviews(app_id: str, since_days: int = REVIEW_SINCE_DAYS) -> list[dict]:
    """Newest customer reviews for one app within since_days:
    [{rating, title, body, date}]. [] when unconfigured/failed."""
    config = asc_config()
    if config is None:
        return []
    payload = _asc_get(f"/v1/apps/{app_id}/customerReviews"
                       "?sort=-createdDate&limit=50", config) or {}
    cutoff = time.time() - since_days * 86400
    reviews = []
    for item in payload.get("data", []):
        attrs = (item.get("attributes") or {}) if isinstance(item, dict) else {}
        created = attrs.get("createdDate", "")
        if _review_ts(created) >= cutoff:
            reviews.append({"rating": attrs.get("rating"),
                            "title": attrs.get("title", "") or "",
                            "body": attrs.get("body", "") or "",
                            "date": created})
    return reviews


def sales_summary() -> dict:
    # ponytail: salesReports needs a vendor number + gzip TSV parsing — skipped;
    # reviews are the roadmap signal. Add when the owner asks for revenue-by-app.
    return {"configured": asc_config() is not None, "available": False,
            "note": "salesReports not implemented — reviews are the core signal"}


def review_summary(force: bool = False) -> dict:
    """Portfolio review feed for the app + scout, cached 1h:
    {configured, apps: [{id, name, recent_reviews: [...]}]}."""
    config = asc_config()
    if config is None:
        return {"configured": False, "apps": [],
                "note": "Add ~/.hermes/asc.json with {key_path, key_id, "
                        "issuer_id} (App Store Connect API key) to see live "
                        "user reviews here."}
    now = time.time()
    if (not force and _SUMMARY_CACHE["data"] is not None
            and now - _SUMMARY_CACHE["fetched"] < SUMMARY_CACHE_SECONDS):
        return _SUMMARY_CACHE["data"]
    if asc_jwt(config) is None:
        return {"configured": False, "apps": [],
                "note": "asc.json is present but the ES256 token could not be "
                        "signed — install pyjwt in the relay venv."}
    apps = [{**app, "recent_reviews": recent_reviews(app["id"])}
            for app in list_apps()]
    summary = {"configured": True, "apps": apps, "fetched": now,
               "note": "" if apps else "ASC answered with no apps — check the key's access."}
    _SUMMARY_CACHE.update(data=summary, fetched=now)
    return summary


def complaint_brief(summary: dict | None = None, cap: int = 1200) -> str:
    """Recent 1-3★ reviews as one compact block for the scout prompt.
    '' when unconfigured or when users are happy."""
    summary = summary if summary is not None else review_summary()
    if not summary.get("configured"):
        return ""
    lines = []
    for app in summary.get("apps", []):
        for review in app.get("recent_reviews", []):
            rating = review.get("rating")
            if isinstance(rating, int) and 1 <= rating <= 3:
                lines.append(f"{app.get('name', '?')} {rating}★ "
                             f"\"{review.get('title', '')}\": "
                             f"{review.get('body', '')[:160]}")
    return "\n".join(lines)[:cap]
