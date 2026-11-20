"""Tests for the Sentry pre-fetch helpers (no network)."""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import fetch_sentry  # noqa: E402  (importable without SENTRY_AUTH_TOKEN)


def event(breadcrumbs=20, frames=30):
    return {
        "message": "m",
        "tags": [{"key": "environment", "value": "production"}],
        "entries": [
            {"type": "exception", "data": {"values": [{
                "type": "TypeError",
                "value": "x is null",
                "stacktrace": {"frames": [
                    {"filename": f"app/f{i}.tsx", "function": "f", "lineNo": i, "inApp": True, "context": []}
                    for i in range(frames)
                ]},
            }]}},
            {"type": "breadcrumbs", "data": {"values": [{"category": "nav", "i": i} for i in range(breadcrumbs)]}},
            {"type": "request", "data": {"cookies": "secret"}},
        ],
    }


class TrimEventTest(unittest.TestCase):
    def test_keeps_last_frames_and_breadcrumbs(self):
        out = fetch_sentry.trim_event(event())
        frames = out["exceptions"][0]["frames"]
        self.assertEqual(len(frames), 25)
        self.assertEqual(frames[-1]["file"], "app/f29.tsx")  # closest to the crash survives
        self.assertEqual(len(out["breadcrumbs"]), 15)
        self.assertEqual(out["breadcrumbs"][-1]["i"], 19)

    def test_flattens_tags_and_drops_request_data(self):
        out = fetch_sentry.trim_event(event())
        self.assertEqual(out["tags"], {"environment": "production"})
        self.assertNotIn("secret", repr(out))

    def test_handles_event_without_entries(self):
        self.assertEqual(fetch_sentry.trim_event({})["exceptions"], [])


class IsCandidateTest(unittest.TestCase):
    issue = {"shortId": "WEB-1A", "project": {"slug": "web"}}

    def test_excludes_ids_mentioned_in_exclude_text(self):
        self.assertFalse(fetch_sentry.is_candidate(self.issue, "WEB-1A\t2026-11-20\tfixed\n"))
        self.assertTrue(fetch_sentry.is_candidate(self.issue, "API-7\t2026-11-20\tfixed\n"))

    def test_project_filter(self):
        with mock.patch.object(fetch_sentry, "PROJECTS", {"api"}):
            self.assertFalse(fetch_sentry.is_candidate(self.issue, ""))
        with mock.patch.object(fetch_sentry, "PROJECTS", {"web"}):
            self.assertTrue(fetch_sentry.is_candidate(self.issue, ""))


if __name__ == "__main__":
    unittest.main()
