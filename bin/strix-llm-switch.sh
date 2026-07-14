#!/usr/bin/env bash
# strix-llm-switch.sh — flip the :8001 local LLM between the driver options.
#   Usage:  strix-llm-switch.sh qwen | qwen27 | gemma
#
# All are systemd --user services that bind :8001 (only one runs at a time):
#   qwen   -> llama-server.service          (Qwen3.6-35B-A3B MoE, 3B active, ~78 t/s)
#   qwen27 -> llama-server-qwen27b.service  (Qwen3.6-27B DENSE + MTP, vision, ~78 t/s) [default 2026-07-15]
#   gemma  -> llama-server-gemma.service    (Gemma-4-26B-A4B MoE + MTP, vision)
# The cf-strix-watchdog reads ~/.config/strix-llm-unit to know which one to
# revive on a :8001 wedge, so flipping is a single source of truth.
set -euo pipefail
TARGET="${1:-}"
UNIT_FILE="$HOME/.config/strix-llm-unit"
ALL_UNITS="llama-server llama-server-qwen27b llama-server-gemma"
case "$TARGET" in
  qwen)   ACTIVE="llama-server";;
  qwen27) ACTIVE="llama-server-qwen27b";;
  gemma)  ACTIVE="llama-server-gemma";;
  *) echo "usage: $0 qwen|qwen27|gemma"; exit 1;;
esac

echo "switching :8001 -> $TARGET ($ACTIVE.service)"
# Stop + disable every OTHER LLM unit so nothing fights for :8001.
for u in $ALL_UNITS; do
  [ "$u" = "$ACTIVE" ] && continue
  systemctl --user stop "$u.service"    2>/dev/null || true
  systemctl --user disable "$u.service" 2>/dev/null || true
done
mkdir -p "$(dirname "$UNIT_FILE")"; echo "$ACTIVE" > "$UNIT_FILE"   # watchdog follows this
systemctl --user enable  "$ACTIVE.service" 2>/dev/null || true
systemctl --user restart "$ACTIVE.service"

echo -n "waiting for :8001 "
for i in $(seq 1 50); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/v1/models 2>/dev/null || true)
  [ "$code" = "200" ] && { echo " up"; break; }
  echo -n "."; sleep 3
done
model=$(curl -s http://127.0.0.1:8001/v1/models 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "?")
echo "now serving on :8001 : $model"
echo "watchdog will revive : $(cat "$UNIT_FILE").service"
