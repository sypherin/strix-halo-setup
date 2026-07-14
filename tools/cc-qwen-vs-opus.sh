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

BASE="$HOME/cc-headtohead-thorough"
QDIR="$BASE/qwen"; ODIR="$BASE/opus"
mkdir -p "$QDIR" "$ODIR"

# ---- the task both models must complete (THOROUGH / GSD-style spec) ---------
# This version externalises the senior-engineer judgment (validation, timeouts,
# edge cases, end-to-end verify) that a strong model does unprompted but a
# weaker one needs told. Point: show how much the harness/spec closes the gap.
read -r -d '' TASK <<'EOF'
Build a PRODUCTION-QUALITY service-liveness watchdog CLI in Python from scratch in the current directory. Treat this as code that will run unattended against real services — robustness matters as much as passing tests.

FUNCTIONAL REQUIREMENTS
1. config.json listing services, each with: name, health_url, fail_threshold (positive int), restart_cmd (a string OR a list of args).
2. watchdog.py that:
   - probes each service's health_url with a BOUNDED timeout (must never hang on a dead/slow endpoint)
   - tracks CONSECUTIVE failures per service (reset to 0 on a success)
   - when consecutive failures reach fail_threshold, runs restart_cmd via subprocess (accept restart_cmd as EITHER a string or an arg list); with --dry-run, do NOT actually run it, just log the intended action
   - enforces a cooldown so the same service is not restarted twice within 60 seconds
   - has a --once mode (one probe pass then exit) plus a continuous mode
   - uses STRUCTURED logging (JSON lines: timestamp, service, event, level)

ROBUSTNESS REQUIREMENTS (do NOT skip)
   - VALIDATE config on load: raise a clear, specific error if a service is missing a required field, fail_threshold is not a positive int, or restart_cmd is the wrong type. Never crash with a raw KeyError/IndexError on bad input.
   - handle subprocess failures gracefully (non-zero exit, command-not-found, timeout) — log and continue, never crash the whole watchdog
   - treat a probe that raises ANY exception (not just one library's error type) as a failure

TESTS (test_watchdog.py, pytest, MOCK all probes + subprocess — no real network or process spawn). Must cover:
   - consecutive-failure counting + success resetting the counter
   - threshold triggering a restart, and cooldown preventing a second restart within the window
   - --dry-run does NOT spawn a subprocess; live mode DOES
   - restart_cmd given as a STRING and as a LIST both work
   - INVALID config (missing field / wrong type / non-positive threshold) raises the expected error
   - a probe raising an unexpected exception is counted as a failure

DONE CRITERIA (all required)
   - run `python -m pytest -q` and fix until ALL tests pass
   - THEN exercise the real CLI end-to-end: run `python watchdog.py --once --dry-run` against config.json and confirm it loads, probes, and logs without error
   - report what you built, the final test count, and the CLI run output
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
