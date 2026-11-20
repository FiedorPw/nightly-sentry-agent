#!/usr/bin/env python3
"""Validate the agent's result.json and turn it into shell-friendly output.

Subcommands (used by run.sh):
  count FILE                  -> number of issues in issues.json
  validate FILE REPO...       -> exit 1 with a message if result.json breaks the contract
  decisions FILE DATE         -> "<short_id>\t<date>\t<verdict>" lines for state/handled.tsv
  prs FILE RUN_DIR            -> "<repo>\t<short_id>\t<title>" lines; writes pr_body_<repo>.md
"""
from __future__ import annotations

import json
import os
import re
import sys

# Sentry short IDs look like WEB-1A / MY_PROJECT-42. A strict pattern keeps agent
# output from smuggling tabs, newlines or shell/path characters into the TSV state
# file, file names or the exclude matching.
# Used with fullmatch(): `$` alone would also accept a trailing "\n".
SHORT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")


def valid_short_id(value) -> bool:
    # Non-strings are rejected outright instead of being str()-ed into something valid
    return isinstance(value, str) and SHORT_ID.fullmatch(value) is not None


def has_control_chars(text: str) -> bool:
    return any(ord(c) < 32 or ord(c) == 127 for c in text)
VERDICTS = {"fixed", "skip_noise", "skip_low_impact", "skip_hard", "skip_duplicate", "abandoned"}
# PR description footer, so reviewers know where the PR came from
FOOTER = (
    "\n\n---\nOpened by nightly-sentry-agent - review before merging.\n\n"
    "🤖 Generated with [Claude Code](https://claude.com/claude-code)\n"
)


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def validate(data: dict, repos: set[str]) -> list[str]:
    """Hand-rolled check of result.schema.json (no jsonschema dependency needed)."""
    if not isinstance(data.get("decisions"), list) or not isinstance(data.get("prs"), list):
        return ["result.json needs 'decisions' and 'prs' arrays"]
    errors = []
    for d in data["decisions"]:
        if d.get("verdict") not in VERDICTS or not valid_short_id(d.get("short_id")):
            errors.append(f"bad decision: {d}")
    seen_repos = set()
    for pr in data["prs"]:
        repo = pr.get("repo")
        if not isinstance(repo, str) or repo not in repos:
            errors.append(f"unknown repo: {repo}")
        if not valid_short_id(pr.get("short_id")):
            errors.append(f"bad short_id for {repo}: {pr.get('short_id')!r}")
        if repo in seen_repos:
            errors.append(f"more than one PR for {repo}")
        seen_repos.add(repo)
        title = pr.get("title")
        # Titles go to the shell as one tab-separated field: no control characters
        if not isinstance(title, str) or not title or len(title) > 120 or has_control_chars(title):
            errors.append(f"bad title for {repo}: {title!r}")
        if not isinstance(pr.get("body"), str) or not pr.get("body"):
            errors.append(f"empty body for {repo}")
    return errors


def main() -> None:
    cmd, path = sys.argv[1], sys.argv[2]
    try:
        data = load(path)
    except json.JSONDecodeError as exc:
        # The agent wrote broken JSON: a clear one-liner for run.log, not a traceback
        sys.exit(f"{path} is not valid JSON: {exc}")
    if cmd == "count":
        print(len(data["issues"]))
    elif cmd == "validate":
        errors = validate(data, set(sys.argv[3:]))
        if errors:
            print("\n".join(errors), file=sys.stderr)
            sys.exit(1)
    elif cmd == "decisions":
        for d in data["decisions"]:
            print(f"{d['short_id']}\t{sys.argv[3]}\t{d['verdict']}")
    elif cmd == "prs":
        run_dir = sys.argv[3]
        for pr in data["prs"]:
            with open(os.path.join(run_dir, f"pr_body_{pr['repo']}.md"), "w", encoding="utf-8") as fh:
                fh.write(pr["body"].rstrip() + FOOTER)
            print(f"{pr['repo']}\t{pr['short_id']}\t{pr['title']}")
    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
