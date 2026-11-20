# nightly-sentry-agent

Every night, a small box (a Raspberry Pi is enough) looks at your new Sentry errors, lets
[Claude Code](https://claude.com/claude-code) decide which ones are **worth fixing and
easy to fix**, fixes them test-first, re-runs your tests on its own and opens a pull
request. When nothing qualifies, it does nothing.

```
systemd timer 03:00 ─► run.sh
  1. per repo: clone/fetch, branch nightly/sentry-<stamp> from origin/$BASE_BRANCH, install deps
  2. open PRs (gh) + recent decisions (state/handled.tsv)
  3. fetch_sentry.py ─► runs/<stamp>/issues.json         ← only place the Sentry token is used
     nothing new → exit 0
  4. optional dev server + Playwright MCP limited to its origin
  5. claude -p   (no Sentry/GitHub tokens, no push, no network tools)
       triage → failing test → fix → commit → result.json
  6. agent_result.py validate → decisions appended to state/handled.tsv
  7. per PR: test gate = the repo's own pre-push hook
       fail → nothing pushed;  pass → git push + gh pr create
```

## Why it is built this way

- **Judgement in the model, everything else in bash.** Fetching, branching, the test
  gate, pushing and opening PRs are deterministic shell steps. Claude only decides and
  edits code, and it writes its decision to a JSON file the script validates.
- **The agent never holds a secret.** Sentry data is pre-fetched into a file, and the
  push and PR happen after Claude exits. `SENTRY_AUTH_TOKEN`, `GH_TOKEN` and
  `GITHUB_TOKEN` are stripped from Claude's environment.
- **Don't trust, verify.** The script re-runs the repository's own pre-push hook before
  pushing. A green claim in `result.json` is not enough.
- **Sentry data is untrusted input.** Error messages contain user-controlled text, so the
  prompt treats them as evidence only and the tool allow-list is narrow (see
  [Security](#security)).

## Requirements

- Linux (arm64 or x86_64), bash, git, python3 (stdlib only), curl, [gh](https://cli.github.com/)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI
- Whatever your repositories need to install and test: node/bun/pnpm, uv/poetry, ...
- For browser checks: node (`npx`) and `npx playwright install --with-deps chromium`

A Raspberry Pi 5 with 8 GB RAM and a USB SSD runs it fine. A dev server and Chromium on an SD card is painful.

## Quick start

```bash
git clone <this repo> ~/nightly-sentry-agent && cd ~/nightly-sentry-agent
cp .env.example .env && chmod 600 .env && $EDITOR .env    # tokens + SENTRY_ORG + GH_REPOS
DRY_RUN=1 ./run.sh                                       # full run, no push / PR
ls runs/*/                                               # issues.json, result.json, run.log, gate_*.log
```

Leave `DRY_RUN=1` for a few nights and read `runs/<stamp>/result.json`. When the
decisions look sane, set `DRY_RUN=0`.

### Tokens

| Variable | What | Scope |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` (uses your Claude subscription) or `ANTHROPIC_API_KEY` | - |
| `SENTRY_AUTH_TOKEN` | Sentry → User settings → Personal Tokens | `org:read`, `project:read`, `event:read` |
| `GH_TOKEN` | GitHub fine-grained PAT, only the repos in `GH_REPOS` | Contents RW, Pull requests RW |

Turn on **branch protection with required review** on your base branch, so even a
leaked `GH_TOKEN` can only push `nightly/*` branches and open PRs.

## Configuration

Everything is an environment variable; [.env.example](.env.example) lists them all with
defaults. The most important ones:

| Variable | Default | Meaning |
|---|---|---|
| `SENTRY_ORG` | (required) | organization slug |
| `SENTRY_BASE_URL` | `https://sentry.io` | `https://de.sentry.io` for EU organizations |
| `SENTRY_PROJECTS` | all | comma-separated project slugs |
| `GH_REPOS` | (required) | `owner/name` list, cloned into `work/<name>` |
| `BASE_BRANCH` | `main` | branch to start from and target PRs at |
| `ALLOWED_BASH` | none | `;`-separated command prefixes the agent may run (`npm test;uv run pytest`) |
| `DEV_SERVER_REPO` / `_CMD` / `_URL` | off | dev server for Playwright MCP checks |
| `MODEL` / `EFFORT` | `claude-opus-5-5` / `high` | Claude Code model and effort |
| `MIN_EVENTS_24H` / `MIN_USERS` | `5` / `2` | "worth fixing" thresholds |
| `MAX_FIX_LINES` / `MAX_FIX_FILES` | `50` / `3` | "easy" thresholds |
| `RETRIAGE_DAYS` | `7` | how long a decided issue is left alone |
| `CONTEXT_FILE` | `./context.md` | project-specific instructions appended to the prompt |
| `DRY_RUN` | `0` | `1` = everything except push and PR |

### Project context

Put what the agent must know about *your* project in `context.md` (gitignored):
which Sentry project maps to which repository, how to run a single test, and the things
it must never touch (e.g. "staging and prod share one database, never write data").
Repository `AGENTS.md` / `CLAUDE.md` files are read too.

### Per-repository hooks

By default dependencies are installed from the lockfile (bun, pnpm, npm, uv, poetry) and
the test gate is the repository's **pre-push hook** (`git rev-parse --git-path hooks`
honours `core.hooksPath`, so husky and `.githooks/` work). Override either with an
executable script:

```
repo-hooks/<repo-name>/setup.sh   # install dependencies
repo-hooks/<repo-name>/gate.sh    # must exit 0 for a PR to be opened
```

A repository without a pre-push hook or `gate.sh` never gets a PR.

## Running nightly with systemd

```bash
sudo useradd -m -s /bin/bash sentry-agent             # then install claude, gh, bun/uv... as this user
sudo git clone <this repo> /opt/nightly-sentry-agent  # root-owned: runs can't modify the code
sudo install -m 600 /opt/nightly-sentry-agent/.env.example /etc/nightly-sentry-agent.env
sudo $EDITOR /etc/nightly-sentry-agent.env            # tokens + SENTRY_ORG + GH_REPOS
sudo $EDITOR /etc/nightly-sentry-agent.context.md     # optional project context
sudo cp /opt/nightly-sentry-agent/systemd/nightly-sentry-agent.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start nightly-sentry-agent.service && journalctl -fu nightly-sentry-agent
sudo systemctl enable --now nightly-sentry-agent.timer
```

`EnvironmentFile=` is read by systemd as root, so the token file stays unreadable for
the agent user. Clones, run logs and state live in `/var/lib/nightly-sentry-agent`.
Adjust the user and `PATH` in the unit to your setup.

## Security

Sentry events carry user-controlled text, and the agent writes and runs code (tests).
Assume that code can be hostile. What the script does about it:

1. **No secrets next to agent-influenced code.** `SENTRY_AUTH_TOKEN`, `GH_TOKEN` and
   `GITHUB_TOKEN` are stripped from Claude's environment. Dependency installs, the dev
   server and the test gate run with *all* tokens stripped.
2. **Narrow tools.** Claude is denied `git push`, `gh`, `curl`, `wget`, WebFetch and
   WebSearch, and may run only git plus the prefixes in `ALLOWED_BASH`.
3. **Push from a clean room.** The agent's clone never runs next to the token. The
   commit SHA is pinned before the gate. After the gate, a throwaway bare repo fetches
   exactly that commit locally (without secrets) and the base branch from GitHub. The
   checks run again on that SHA, and then `<sha>:refs/heads/<branch>` is pushed.
   Credentialed git ignores `~/.gitconfig` and the system config, disables hooks and
   fsmonitor, forces TLS verification, and gets a fresh `gh` config dir.
4. **Nothing left running.** The gate runs in its own process group, killed when it
   ends, and the dev server is stopped before any token is used again.
5. **`.git` integrity.** A SHA-256 of `.git/config`, `commondir`, `hooks/` and `info/`
   is compared with the post-setup value. On a mismatch the clone is deleted and
   re-cloned, so a tampered config never meets `git fetch` with a token.
6. **Protected paths.** A diff touching `PROTECTED_PATHS` (default `.github/ .githooks/
   .husky/ .gitattributes .gitmodules`) never becomes a PR, so the agent can't weaken
   the gate or CI. Leave the PAT without the *Workflows* permission too.
7. **Strict output.** `result.json` is validated (verdicts, repo names, short-ID pattern,
   no control characters) before anything uses it.
8. **Humans merge.** Every change arrives as a PR against a protected branch.

**Known limits.** These are speed bumps, not a hard boundary, as long as the agent and the
orchestrator share one Unix user:
- A same-user process can read `/proc/<pid>/environ` of `run.sh`, which holds the tokens.
  A process that detaches itself (a new session) also survives the gate's process-group kill.
- Commands Claude runs inherit `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`.
- Binaries in user-writable directories can be replaced: install `git`, `gh` and
  `python3` system-wide (the unit puts system dirs first in `PATH`; `run.sh` warns otherwise).
- The gate runs tests the agent wrote. It proves "nothing obvious broke", not "the fix is right".
- With `.env` next to `run.sh` (handy for trying it out) the file is readable by agent code.
  Use the systemd layout above for unattended runs.

So keep the machine boring: no production secrets in the repositories' `.env` files,
minimal token scopes, nothing else of value on the box. A separate Unix user for the
Claude + gate phase is the next hardening step (contributions welcome).

## Development

```bash
python3 -m unittest discover -s tests -v
bash -n run.sh && shellcheck run.sh
```

## License

[MIT](LICENSE)
