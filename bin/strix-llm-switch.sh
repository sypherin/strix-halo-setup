#!/usr/bin/env bash
# strix-llm-switch.sh — flip the :8001 local LLM between Gemma 4 and Qwen 3.6.
#   Usage:  strix-llm-switch.sh gemma | qwen
#
# Both are systemd --user services that bind :8001:
#   qwen  -> llama-server.service        (Qwen3.6-35B-A3B)
#   gemma -> llama-server-gemma.service  (Gemma-4-26B-A4B)
# A liveness watchdog can read ~/.config/strix-llm-unit to know which unit to
# revive on a :8001 wedge, so flipping is a single source of truth.
set -euo pipefail
TARGET="${1:-}"
UNIT_FILE="$HOME/.config/strix-llm-unit"
case "$TARGET" in
  qwen)  ACTIVE="llama-server";       OTHER="llama-server-gemma";;
  gemma) ACTIVE="llama-server-gemma"; OTHER="llama-server";;
  *) echo "usage: $0 gemma|qwen"; exit 1;;
esac

echo "switching :8001 -> $TARGET ($ACTIVE.service)"
systemctl --user stop "$OTHER.service"    2>/dev/null || true
systemctl --user disable "$OTHER.service" 2>/dev/null || true
mkdir -p "$(dirname "$UNIT_FILE")"; echo "$ACTIVE" > "$UNIT_FILE"   # watchdog follows this
systemctl --user enable  "$ACTIVE.service" 2>/dev/null || true
systemctl --user restart "$ACTIVE.service"

echo -n "waiting for :8001 "
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/v1/models 2>/dev/null || true)
  [ "$code" = "200" ] && { echo " up"; break; }
  echo -n "."; sleep 3
done
model=$(curl -s http://127.0.0.1:8001/v1/models 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "?")
echo "now serving on :8001 : $model"
echo "watchdog will revive : $(cat "$UNIT_FILE").service"
