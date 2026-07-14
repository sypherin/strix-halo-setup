#!/usr/bin/env bash
# vlm-window.sh — single source of truth for which on-GPU model servers are
# kept warm only during business hours: weekdays 08:00–20:00 local (SGT).
# Out-of-window they're stopped (nobody uses them overnight/weekends).
#
# WINDOWED SERVICES (none of these have off-hours consumers):
#   - llama-vlm-bom  (:8080, neo /vlm + CF-BOM 32B)
#   - llama-surya2   (:8093, document OCR shadow)
#   - surya-server   (:8090, Surya v1 layout+OCR podman container surya-only)
# NOT windowed (overnight consumers — leave 24/7): llama-server-gemma (:8001,
#   news ingest + Lyra muses).
#
#   ./vlm-window.sh check        → prints "in" or "out", exit 0/1
#   ./vlm-window.sh reconcile    → start windowed services in-window, stop them out
#
# Used by both the reconcile timer AND cf-strix-watchdog (so the watchdog only
# revives a windowed service during business hours and never fights the schedule).
set -euo pipefail
SERVICES=(llama-vlm-bom llama-surya2 surya-server)
START_HOUR=8
END_HOUR=20          # exclusive — last warm minute is 19:59

in_window() {
  local dow hour
  dow=$(date +%u)    # 1=Mon … 7=Sun
  hour=$(date +%H)   # 00–23, zero-padded
  hour=$((10#$hour)) # force base-10 (08/09 aren't octal)
  [[ "$dow" -le 5 && "$hour" -ge "$START_HOUR" && "$hour" -lt "$END_HOUR" ]]
}

case "${1:-check}" in
  check)
    if in_window; then echo in; exit 0; else echo out; exit 1; fi
    ;;
  reconcile)
    if in_window; then
      for s in "${SERVICES[@]}"; do systemctl --user start "$s" 2>/dev/null || true; done
      echo "in-window → ensured started: ${SERVICES[*]}"
    else
      for s in "${SERVICES[@]}"; do systemctl --user stop "$s" 2>/dev/null || true; done
      echo "out-of-window → ensured stopped: ${SERVICES[*]}"
    fi
    ;;
  *)
    echo "usage: $0 {check|reconcile}"; exit 2 ;;
esac
