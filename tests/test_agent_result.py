"""Tests for the result.json contract that guards push + PR."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import agent_result  # noqa: E402

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "agent_result.py")
REPOS = {"web", "api"}


def pr(repo="web", title="fix(map): guard ref (Fixes WEB-1)", body="## Root cause\nx"):
    return {"repo": repo, "short_id": "WEB-1", "title": title, "body": body}


class ValidateTest(unittest.TestCase):
    def test_accepts_valid_result(self):
        data = {"decisions": [{"short_id": "WEB-1", "verdict": "fixed", "reason": "x"}], "prs": [pr()]}
        self.assertEqual(agent_result.validate(data, REPOS), [])

    def test_accepts_nothing_to_do(self):
        # "Nothing worth fixing" is a valid, normal outcome
        self.assertEqual(agent_result.validate({"decisions": [], "prs": []}, REPOS), [])

    def test_rejects_missing_arrays(self):
        self.assertTrue(agent_result.validate({"decisions": []}, REPOS))

    def test_rejects_unknown_verdict(self):
        data = {"decisions": [{"short_id": "A", "verdict": "yolo", "reason": ""}], "prs": []}
        self.assertTrue(agent_result.validate(data, REPOS))

    def test_rejects_repo_outside_config(self):
        self.assertIn("unknown repo: other", agent_result.validate({"decisions": [], "prs": [pr("other")]}, REPOS))

    def test_rejects_two_prs_for_one_repo(self):
        data = {"decisions": [], "prs": [pr(), pr()]}
        self.assertIn("more than one PR for web", agent_result.validate(data, REPOS))

    def test_rejects_title_that_would_break_tsv(self):
        for title in ["a\tb", "a\nb", "a\r", "a\x1b[31m", "", "x" * 121, 42]:
            with self.subTest(title=title):
                self.assertTrue(agent_result.validate({"decisions": [], "prs": [pr(title=title)]}, REPOS))

    def test_rejects_short_id_that_would_break_tsv(self):
        for sid in ["A\tB", "A\nB", "A\n", "", "../x", "a b", 123, None]:
            with self.subTest(short_id=sid):
                bad_decision = {"decisions": [{"short_id": sid, "verdict": "fixed", "reason": ""}], "prs": []}
                self.assertTrue(agent_result.validate(bad_decision, REPOS))
                bad_pr = {"decisions": [], "prs": [dict(pr(), short_id=sid)]}
                self.assertTrue(agent_result.validate(bad_pr, REPOS))

    def test_rejects_empty_body(self):
        self.assertTrue(agent_result.validate({"decisions": [], "prs": [pr(body="")]}, REPOS))


class CliTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)

    def test_broken_json_gives_one_line_error(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write("{broken")
        proc = self.run_cli("validate", fh.name, "web")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("is not valid JSON", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_prs_writes_body_with_footer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "result.json")
            with open(path, "w") as fh:
                json.dump({"decisions": [], "prs": [pr()]}, fh)
            proc = self.run_cli("prs", path, tmp)
            self.assertEqual(proc.stdout, "web\tWEB-1\tfix(map): guard ref (Fixes WEB-1)\n")
            with open(os.path.join(tmp, "pr_body_web.md")) as fh:
                self.assertIn("Generated with [Claude Code]", fh.read())


if __name__ == "__main__":
    unittest.main()
