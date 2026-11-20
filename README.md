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
sudo useradd -m -s /bin/bash sentry-agent
sudo -iu sentry-agent git clone <this repo> ~/nightly-sentry-agent
sudo install -m 600 -o root -g root ~sentry-agent/nightly-sentry-agent/.env.example /etc/nightly-sentry-agent.env
sudo $EDITOR /etc/nightly-sentry-agent.env
sudo cp ~sentry-agent/nightly-sentry-agent/systemd/nightly-sentry-agent.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start nightly-sentry-agent.service && journalctl -fu nightly-sentry-agent
sudo systemctl enable --now nightly-sentry-agent.timer
```

`EnvironmentFile=` is read by systemd as root, so the token file can stay unreadable
for the agent user. Adjust user, paths and `PATH` in the unit to your setup.

## Security

What protects you, and what does not:

1. **Tokens never reach Claude's environment**, and Claude is denied `git push`, `gh`,
   `curl`, `wget`, WebFetch and WebSearch.
2. **The allow-list is not a sandbox.** The agent writes and runs code (tests), and that
   code runs as the agent user. So:
3. **Keep the machine boring:** no production secrets in the repositories' `.env` files,
   minimal token scopes, a dedicated Unix user.
4. **Humans merge.** Every change arrives as a PR against a protected branch, after an
   independent test gate.

A process can read `/proc/<pid>/environ` of its parent when both run as the same user.
For full separation, run the push/PR step as a different user.

## Development

```bash
python3 -m unittest discover -s tests -v
bash -n run.sh && shellcheck run.sh
```

## License

[MIT](LICENSE)
