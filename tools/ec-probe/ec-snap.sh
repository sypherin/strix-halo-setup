#!/usr/bin/env bash
# ec-snap.sh <label> — capture ONE read-only snapshot of the EC's 256 registers.
# Non-interactive (safe to run via the ! prefix). Only ever READS.
#   sudo ./ec-snap.sh idle1
set -euo pipefail
LABEL="${1:?usage: sudo ec-snap.sh <label>}"
OUT="$(cd "$(dirname "$0")" && pwd)/ec-dumps"
IO=/sys/kernel/debug/ec/ec0/io
mkdir -p "$OUT"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
if [[ ! -e "$IO" ]]; then
  modprobe ec_sys 2>/dev/null || { echo "FAILED to load ec_sys (read-only). Secure Boot on? run: mokutil --sb-state"; exit 1; }
fi
[[ -e "$IO" ]] || { echo "no $IO"; exit 1; }
dd if="$IO" bs=256 count=1 2>/dev/null | xxd > "$OUT/$LABEL.hex"
echo "captured $LABEL.hex ($(date +%H:%M:%S)) — read-only, nothing written"
