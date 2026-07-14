#!/usr/bin/env bash
# ec-discover.sh — Phase 0, READ-ONLY EC discovery for the Bosgame M5 (AXB35).
#
# Goal: map which of the Embedded Controller's 256 registers track temperature,
# fan duty/RPM, and power mode — by dumping them while conditions change.
# This script ONLY READS. It never writes an EC register. The ec_sys module is
# loaded WITHOUT write_support, so writes are impossible even by accident.
#
# Usage:  sudo ./ec-discover.sh
# Output: ./ec-dumps/  (timestamped hex dumps + a diff summary)
#
# It will pause and prompt YOU to: idle, trigger load, and press the power-mode
# button, capturing a dump at each step so the diffs reveal the registers.
set -euo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/ec-dumps"
mkdir -p "$OUT"
IO=/sys/kernel/debug/ec/ec0/io

# ---- preflight -------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then echo "run with sudo: sudo $0"; exit 1; fi
if [[ ! -e "$IO" ]]; then
  echo "EC interface missing — loading ec_sys (read-only)…"
  modprobe ec_sys 2>/dev/null || { echo "FAILED to load ec_sys. Secure Boot on? check: mokutil --sb-state"; exit 1; }
fi
[[ -e "$IO" ]] || { echo "still no $IO — aborting"; exit 1; }
echo "EC read interface: $IO  (256 bytes, READ-ONLY)"
echo "dumps → $OUT"
echo

dump () { # $1 = label
  local f="$OUT/$1.hex"
  dd if="$IO" bs=256 count=1 2>/dev/null | xxd > "$f"
  echo "  captured: $1.hex"
}

avg_dump () { # $1 = label, $2 = seconds — median-ish: 3 dumps a second apart, keep last
  local label="$1" secs="${2:-3}"
  for i in $(seq 1 "$secs"); do dd if="$IO" bs=256 count=1 2>/dev/null | xxd > "$OUT/$label.hex"; sleep 1; done
  echo "  captured: $label.hex (after ${secs}s)"
}

pause () { read -rp "  >>> $1 — then press ENTER " _; }

echo "=== STEP 1/5: baseline idle ==="
pause "let the box sit idle ~10s"
avg_dump idle1 5

echo
echo "=== STEP 2/5: under load ==="
echo "  In your Claude session, say 'run the load probe' so it drives Gemma."
pause "start the load, wait ~10s so the fan ramps, THEN press ENTER"
avg_dump load1 5

echo
echo "=== STEP 3/5: power mode — press ONCE ==="
pause "press the front power-mode button ONCE"
avg_dump mode_a 3

echo
echo "=== STEP 4/5: power mode — press AGAIN ==="
pause "press the front power-mode button ONCE more"
avg_dump mode_b 3

echo
echo "=== STEP 5/5: back to idle, cooled ==="
pause "stop any load, wait ~20s for the fan to settle"
avg_dump idle2 5

# ---- diff summary ----------------------------------------------------------
echo
echo "=== REGISTER DIFF SUMMARY ==="
python3 - "$OUT" <<'PY'
import sys, glob, os
d = sys.argv[1]
def load(name):
    p = os.path.join(d, name + ".hex")
    if not os.path.exists(p): return None
    b = []
    for line in open(p):
        parts = line.split(":")
        if len(parts) < 2: continue
        hexpart = parts[1].split("  ")[0]
        b += [int(x, 16) for x in hexpart.split()]
    return b[:256]

snaps = {n: load(n) for n in ["idle1","load1","mode_a","mode_b","idle2"]}
snaps = {k: v for k, v in snaps.items() if v}
names = list(snaps)
print("registers that CHANGED across snapshots (offset: values):")
hits = []
for off in range(256):
    vals = [snaps[n][off] for n in names]
    if len(set(vals)) > 1:
        hits.append((off, vals))
        print(f"  0x{off:02X} ({off:3d}): " + "  ".join(f"{n}={snaps[n][off]:3d}" for n in names))
print()
print("HEURISTICS:")
for off, vals in hits:
    v = dict(zip(names, vals))
    note = []
    if "idle1" in v and "load1" in v and v["load1"] > v["idle1"] + 8:
        note.append("↑ under load → TEMP or FAN-DUTY candidate")
    if "mode_a" in v and "mode_b" in v and v["mode_a"] != v["mode_b"]:
        note.append("changes with mode button → POWER-MODE candidate")
    if note:
        print(f"  0x{off:02X}: " + "; ".join(note))
if not hits:
    print("  (no registers changed — EC may mirror little here, or timing missed the ramp)")
PY
echo
echo "Done. All read-only. Share the SUMMARY above with Claude to build the register map."
echo "To unload the module afterward:  sudo modprobe -r ec_sys"
