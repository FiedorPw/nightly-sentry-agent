#!/usr/bin/env bash
# nightly-sentry-agent: every night, Sentry issues -> Claude Code triage + fix -> verified PR.
#
# Split of responsibilities (on purpose):
#   - this script: deterministic steps and everything that needs a secret
#     (Sentry API, git push, gh pr create), plus an independent test gate;
#   - Claude: only the judgement (worth fixing? easy?) and the code change.
# Claude runs without the Sentry / GitHub tokens and is not allowed to push.
#
# All configuration comes from the environment (see .env.example). A .env file next
# to this script is loaded automatically; under systemd prefer EnvironmentFile=.
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# `set -a` exports every variable the .env file defines
if [ -f "$AGENT_HOME/.env" ]; then set -a; . "$AGENT_HOME/.env"; set +a; fi

# --- Configuration --------------------------------------------------------------
: "${SENTRY_AUTH_TOKEN:?set SENTRY_AUTH_TOKEN (read-only scopes: org:read, project:read, event:read)}"
: "${SENTRY_ORG:?set SENTRY_ORG (organization slug)}"
: "${GH_TOKEN:?set GH_TOKEN (fine-grained PAT: Contents + Pull requests read/write on GH_REPOS only)}"
: "${GH_REPOS:?set GH_REPOS, space-separated owner/name list, e.g. \"acme/web acme/api\"}"
BASE_BRANCH="${BASE_BRANCH:-main}"
WORK_DIR="${WORK_DIR:-$AGENT_HOME/work}"
STATE_DIR="${STATE_DIR:-$AGENT_HOME/state}"
RUNS_DIR="${RUNS_DIR:-$AGENT_HOME/runs}"
CONTEXT_FILE="${CONTEXT_FILE:-$AGENT_HOME/context.md}"
MODEL="${MODEL:-claude-opus-5-5}"
EFFORT="${EFFORT:-high}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3h}"
ALLOWED_BASH="${ALLOWED_BASH:-}"           # ';'-separated command prefixes (tests, linters)
DEV_SERVER_REPO="${DEV_SERVER_REPO:-}"     # repo name (not owner/name) to run the dev server in
DEV_SERVER_CMD="${DEV_SERVER_CMD:-}"       # e.g. "bunx next dev -p 3100"; empty = no browser checks
DEV_SERVER_URL="${DEV_SERVER_URL:-}"       # e.g. http://localhost:3100
PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.86}"
PLAYWRIGHT_BROWSER="${PLAYWRIGHT_BROWSER:-chromium}"  # Chrome has no Linux arm64 build
MIN_EVENTS_24H="${MIN_EVENTS_24H:-5}"
MIN_USERS="${MIN_USERS:-2}"
MAX_FIX_LINES="${MAX_FIX_LINES:-50}"
MAX_FIX_FILES="${MAX_FIX_FILES:-3}"
RETRIAGE_DAYS="${RETRIAGE_DAYS:-7}"
DRY_RUN="${DRY_RUN:-0}"

STATE="$STATE_DIR/handled.tsv"
STAMP="$(date +%F-%H%M)"
TODAY="$(date +%F)"
RUN_DIR="$RUNS_DIR/$STAMP"
BRANCH="nightly/sentry-$STAMP"
read -ra REPOS <<< "$GH_REPOS"

mkdir -p "$RUN_DIR" "$STATE_DIR" "$WORK_DIR"
touch "$STATE"
# Mirror all output into the run folder; under systemd it also lands in journald
exec > >(tee -a "$RUN_DIR/run.log") 2>&1
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }

# git with GH_TOKEN as credentials (via gh), without touching the global git config
git_auth() { git -c credential.helper= -c 'credential.https://github.com.helper=!gh auth git-credential' "$@"; }

# Install dependencies: repo-hooks/<name>/setup.sh if present, else guess from the lockfile
install_deps() {
  local dir="$1" name="$2" custom="$AGENT_HOME/repo-hooks/$2/setup.sh"
  if [ -x "$custom" ]; then (cd "$dir" && "$custom"); return; fi
  (
    cd "$dir"
    if   [ -f bun.lock ] || [ -f bun.lockb ]; then bun install --frozen-lockfile >/dev/null
    elif [ -f pnpm-lock.yaml ];   then pnpm install --frozen-lockfile >/dev/null
    elif [ -f package-lock.json ]; then npm ci --silent
    fi
    if   [ -f uv.lock ];     then uv sync --quiet
    elif [ -f poetry.lock ]; then poetry install --quiet
    fi
  )
}

# Test gate: repo-hooks/<name>/gate.sh if present, else the repo's own pre-push hook.
# `git rev-parse --git-path hooks` honours core.hooksPath (husky, .githooks, ...).
run_gate() {
  local dir="$1" name="$2" custom="$AGENT_HOME/repo-hooks/$2/gate.sh" hooks
  if [ -x "$custom" ]; then (cd "$dir" && "$custom"); return; fi
  hooks="$(cd "$dir" && git rev-parse --git-path hooks)"
  case "$hooks" in /*) ;; *) hooks="$dir/$hooks" ;; esac
  if [ -x "$hooks/pre-push" ]; then
    (cd "$dir" && "$hooks/pre-push" origin "$(git remote get-url origin)" </dev/null)
    return
  fi
  echo "no test gate for $name: add a pre-push hook or repo-hooks/$name/gate.sh" >&2
  return 1
}

# --- 1. Fresh branch from origin/$BASE_BRANCH in each dedicated clone ------------
for slug in "${REPOS[@]}"; do
  name="${slug#*/}"
  dir="$WORK_DIR/$name"
  if [ ! -d "$dir/.git" ]; then
    log "Cloning $slug"
    git_auth clone --quiet "https://github.com/$slug.git" "$dir"
  fi
  git_auth -C "$dir" fetch --quiet --prune origin
  # Throw away anything a previous run left behind, then branch off the newest base.
  # `clean` without -x keeps ignored files (.env*, node_modules, .venv).
  git -C "$dir" reset --quiet --hard
  git -C "$dir" checkout --quiet -B "$BRANCH" "origin/$BASE_BRANCH"
  git -C "$dir" clean -fdq
  install_deps "$dir" "$name"
done

# --- 2. Inputs for the agent ------------------------------------------------------
for slug in "${REPOS[@]}"; do
  gh pr list --repo "$slug" --state open --limit 100 \
    --json number,title,headRefName,url > "$RUN_DIR/open_prs_${slug#*/}.json"
done

# Issues decided recently are not re-triaged every night.
# Column 2 is an ISO date, so a plain string comparison is a date comparison.
cutoff="$(python3 -c 'import datetime,sys; print(datetime.date.today()-datetime.timedelta(days=int(sys.argv[1])))' "$RETRIAGE_DAYS")"
awk -F'\t' -v cut="$cutoff" '$2 >= cut' "$STATE" > "$RUN_DIR/handled_recent.tsv"

log "Fetching Sentry issues for $SENTRY_ORG"
python3 "$AGENT_HOME/fetch_sentry.py" --exclude-text \
  "$RUN_DIR/handled_recent.tsv" "$RUN_DIR"/open_prs_*.json > "$RUN_DIR/issues.json"
count="$(python3 "$AGENT_HOME/agent_result.py" count "$RUN_DIR/issues.json")"
if [ "$count" -eq 0 ]; then
  log "No new unresolved issues in the last 24 h - nothing to do"
  exit 0
fi
log "$count issue(s) to triage"

# --- 3. Optional dev server so the agent can reproduce UI bugs --------------------
dev_pgid=""
e2e_url=""
cleanup() {
  # Kill the whole process group (package runner -> dev server -> workers)
  if [ -n "$dev_pgid" ]; then kill -- "-$dev_pgid" 2>/dev/null || true; fi
}
trap cleanup EXIT
mcp_args=(--strict-mcp-config)   # never load MCP servers from the user's global config
if [ -n "$DEV_SERVER_CMD" ] && [ -n "$DEV_SERVER_URL" ] && [ -n "$DEV_SERVER_REPO" ]; then
  log "Starting dev server: $DEV_SERVER_CMD"
  setsid bash -c "cd '$WORK_DIR/$DEV_SERVER_REPO' && exec $DEV_SERVER_CMD" \
    > "$RUN_DIR/dev-server.log" 2>&1 &
  dev_pgid=$!
  # Slow machines (a Raspberry Pi) need a while for the first compile: up to 4 min
  for _ in $(seq 1 120); do
    if curl -s -o /dev/null "$DEV_SERVER_URL"; then e2e_url="$DEV_SERVER_URL"; break; fi
    sleep 2
  done
  if [ -n "$e2e_url" ]; then
    # Playwright MCP limited to the dev server origin (a guard rail, not a sandbox)
    origin="$(python3 -c 'import sys,urllib.parse as u; p=u.urlsplit(sys.argv[1]); print(f"{p.scheme}://{p.netloc}")' "$e2e_url")"
    cat > "$RUN_DIR/mcp.json" <<EOF
{"mcpServers": {"playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@$PLAYWRIGHT_MCP_VERSION",
  "--headless", "--isolated", "--browser", "$PLAYWRIGHT_BROWSER", "--allowed-origins", "$origin"]}}}
EOF
    mcp_args+=(--mcp-config "$RUN_DIR/mcp.json")
    export PLAYWRIGHT_BASE_URL="$e2e_url"
  else
    log "WARN: dev server did not come up - agent runs without browser checks"
  fi
fi

# --- 4. Claude: triage + fix -------------------------------------------------------
allowed=(Read Edit Write Glob Grep TodoWrite
  "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)"
  "Bash(git add:*)" "Bash(git commit:*)" "Bash(git restore:*)" "Bash(git reset:*)")
# Project-specific commands (test runners, linters) from ALLOWED_BASH
IFS=';' read -ra extra <<< "$ALLOWED_BASH"
for prefix in "${extra[@]}"; do
  prefix="${prefix#"${prefix%%[![:space:]]*}"}"   # trim leading whitespace
  prefix="${prefix%"${prefix##*[![:space:]]}"}"   # trim trailing whitespace
  [ -n "$prefix" ] && allowed+=("Bash($prefix:*)")
done
[ -n "$e2e_url" ] && allowed+=("mcp__playwright")

repo_lines=""
for slug in "${REPOS[@]}"; do repo_lines+="  - \`${slug#*/}/\` (GitHub $slug)"$'\n'; done
if [ -n "$e2e_url" ]; then
  e2e_line="Dev server: $e2e_url (Playwright MCP limited to this origin; PLAYWRIGHT_BASE_URL is exported)."
else
  e2e_line="Dev server: not available this run - skip browser checks."
fi

# The agent may write only to the run dir, so the schema is copied next to its inputs
cp "$AGENT_HOME/result.schema.json" "$RUN_DIR/"
context=""
[ -f "$CONTEXT_FILE" ] && context="$(printf '\n## Project context\n\n%s\n' "$(cat "$CONTEXT_FILE")")"

prompt="$(cat "$AGENT_HOME/prompt.md")
$context

## This run
- Run dir (inputs; write result.json here): $RUN_DIR
- Schema: $RUN_DIR/result.schema.json
- Repositories (current directory is the workspace), all on branch \`$BRANCH\` created from \`origin/$BASE_BRANCH\`:
$repo_lines- Thresholds: worth fixing = at least $MIN_EVENTS_24H events in 24 h or at least $MIN_USERS users; easy = at most ~$MAX_FIX_LINES changed lines in at most $MAX_FIX_FILES files (tests excluded).
- Commands you may run besides git: ${ALLOWED_BASH:-none configured}
- $e2e_line"

log "Running Claude ($MODEL, effort $EFFORT)"
cd "$WORK_DIR"
set +e
# - Sentry / GitHub tokens are stripped from Claude's environment.
# - In -p mode anything outside the allow-list is refused (nobody is there to approve).
# - The prompt goes through stdin so the variadic --allowedTools can't swallow it.
printf '%s' "$prompt" | env -u SENTRY_AUTH_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  timeout "$CLAUDE_TIMEOUT" claude -p \
    --model "$MODEL" --effort "$EFFORT" \
    --permission-mode acceptEdits \
    --add-dir "$RUN_DIR" \
    "${mcp_args[@]}" \
    --allowedTools "${allowed[@]}" \
    --disallowedTools "Bash(git push:*)" "Bash(gh:*)" "Bash(curl:*)" "Bash(wget:*)" \
      "WebFetch" "WebSearch" \
    --output-format json > "$RUN_DIR/claude.json"
claude_rc=$?
set -e
log "Claude exited with $claude_rc"

# --- 5. Check the agent's answer --------------------------------------------------
result="$RUN_DIR/result.json"
if [ ! -s "$result" ]; then
  log "No result.json - nothing pushed. See $RUN_DIR/claude.json"
  exit 1
fi
repo_names=()
for slug in "${REPOS[@]}"; do repo_names+=("${slug#*/}"); done
if ! python3 "$AGENT_HOME/agent_result.py" validate "$result" "${repo_names[@]}"; then
  log "result.json breaks the contract - nothing pushed"
  exit 1
fi
python3 "$AGENT_HOME/agent_result.py" decisions "$result" "$TODAY" | tee -a "$STATE"

# --- 6. Push + PR, one per repo with a verified fix -------------------------------
# Read from fd 3 so git/gh inside the loop can't eat the loop's input.
while IFS=$'\t' read -r name short_id title <&3; do
  dir="$WORK_DIR/$name"
  slug=""
  for s in "${REPOS[@]}"; do [ "${s#*/}" = "$name" ] && slug="$s"; done
  if [ "$(git -C "$dir" rev-list --count "origin/$BASE_BRANCH..HEAD")" -eq 0 ]; then
    log "$name: agent reported $short_id but made no commit - skipping"
    continue
  fi
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    log "$name: uncommitted changes left behind - skipping"
    printf '%s\t%s\t%s\n' "$short_id" "$TODAY" "gate_failed" >> "$STATE"
    continue
  fi
  # Independent gate: don't trust the agent's word that tests pass
  log "$name: running test gate"
  if ! run_gate "$dir" "$name" > "$RUN_DIR/gate_$name.log" 2>&1; then
    log "$name: test gate FAILED - not pushing (see gate_$name.log)"
    printf '%s\t%s\t%s\n' "$short_id" "$TODAY" "gate_failed" >> "$STATE"
    continue
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "$name: DRY_RUN - would push $BRANCH and open PR: $title"
    continue
  fi
  # --no-verify: the same pre-push hook just passed in the gate above
  git_auth -C "$dir" push --quiet --no-verify -u origin "$BRANCH"
  pr_url="$(gh pr create --repo "$slug" --base "$BASE_BRANCH" --head "$BRANCH" \
    --title "$title" --body-file "$RUN_DIR/pr_body_$name.md")"
  log "$name: opened $pr_url"
done 3< <(python3 "$AGENT_HOME/agent_result.py" prs "$result" "$RUN_DIR")

log "Done"
