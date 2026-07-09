#!/usr/bin/env bash
# ============================================================================
# Claude Code head-to-head: LOCAL Qwen3.6 (via ccr)  vs  Opus 4.8 (cloud)
# ----------------------------------------------------------------------------
# Runs the IDENTICAL complex build task through both, in isolated scratch dirs,
# times each, then runs the resulting pytest suite so you can see who got to
# green and how they compare. Run this yourself in a terminal:
#     bash ~/strix-halo-setup/tools/cc-qwen-vs-opus.sh
# You'll approve nothing interactively — both runs use --dangerously-skip-
# permissions (safe: they only touch the throwaway dirs under ~/cc-headtohead).
# Opus run uses your normal Claude subscription; local run uses :8001, free.
# ============================================================================
set -uo pipefail

BASE="$HOME/cc-headtohead"
QDIR="$BASE/qwen"; ODIR="$BASE/opus"
mkdir -p "$QDIR" "$ODIR"

# ---- the task both models must complete ------------------------------------
read -r -d '' TASK <<'EOF'
Build a service-liveness watchdog CLI in Python from scratch in the current directory. Requirements:
1. config.json listing services, each with: name, health_url, fail_threshold, restart_cmd.
2. watchdog.py that: probes each service's health_url; tracks CONSECUTIVE failures per service (reset to 0 on a success); when a service's failures reach fail_threshold, runs its restart_cmd via subprocess (skip the actual run when --dry-run is passed, just log it); enforces a cooldown so the same service is not restarted twice within 60 seconds; has a --once mode that does exactly one probe pass then exits; uses structured logging.
3. test_watchdog.py: a pytest suite that MOCKS the probe function (no real network) covering: consecutive-failure counting, success resetting the counter, threshold triggering a restart, and cooldown preventing a second restart.
After writing the code, run `python -m pytest -q` and fix any failures until ALL tests pass. Report what you built and the final test result.
EOF

echo "== preflight =="
command -v ccr    >/dev/null || { echo "!! ccr not found"; exit 1; }
command -v claude >/dev/null || { echo "!! claude not found"; exit 1; }
python -c "import pytest" 2>/dev/null || { echo ".. installing pytest"; python -m pip install --user -q pytest; }
ccr status >/dev/null 2>&1 || ccr start
curl -s -o /dev/null -w "" http://127.0.0.1:8001/v1/models || { echo "!! local model on :8001 not responding — start llama-server.service"; exit 1; }
echo "   ccr up, :8001 serving $(curl -s http://127.0.0.1:8001/v1/models | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"].split("/")[-1])')"

run_and_time() {  # $1=label $2=dir $3=launcher-cmd...
  local label="$1" dir="$2"; shift 2
  echo; echo "############ $label ############"
  cd "$dir"
  local s=$(date +%s)
  "$@" -p "$TASK" --dangerously-skip-permissions 2>&1 | tee "$BASE/$(basename "$dir").log"
  local e=$(date +%s)
  echo "-- $label: re-running pytest for the record --"
  python -m pytest -q 2>&1 | tail -6 | tee "$BASE/$(basename "$dir")-pytest.log"
  echo "$((e-s))" > "$BASE/$(basename "$dir").secs"
}

# RUN A: local Qwen3.6 through ccr (ccr code = claude with the router env)
run_and_time "RUN A — LOCAL Qwen3.6 (ccr)" "$QDIR" ccr code

# RUN B: Opus 4.8 = your normal claude (unset router env so it hits Anthropic)
run_and_time "RUN B — Opus 4.8 (cloud)" "$ODIR" env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY claude

# ---- summary ---------------------------------------------------------------
qsecs=$(cat "$BASE/qwen.secs" 2>/dev/null || echo '?')
osecs=$(cat "$BASE/opus.secs" 2>/dev/null || echo '?')
qpass=$(cd "$QDIR" && python -m pytest -q 2>&1 | tail -1)
opass=$(cd "$ODIR" && python -m pytest -q 2>&1 | tail -1)
echo; echo "################## SUMMARY ##################"
printf "  LOCAL Qwen3.6 : %ss  | %s files | pytest: %s\n" "$qsecs" "$(ls "$QDIR" | wc -l)" "$qpass"
printf "  Opus 4.8      : %ss  | %s files | pytest: %s\n" "$osecs" "$(ls "$ODIR" | wc -l)" "$opass"
echo "  inspect the code:  $QDIR   vs   $ODIR"
echo "  full transcripts:  $BASE/qwen.log   $BASE/opus.log"
