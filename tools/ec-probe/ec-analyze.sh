#!/usr/bin/env bash
# ec-analyze.sh — diff all captured EC snapshots, flag temp/fan/mode candidates.
set -euo pipefail
OUT="$(cd "$(dirname "$0")" && pwd)/ec-dumps"
python3 - "$OUT" <<'PY'
import sys, os
d = sys.argv[1]
def load(name):
    p = os.path.join(d, name + ".hex")
    if not os.path.exists(p): return None
    b = []
    for line in open(p):
        parts = line.split(":")
        if len(parts) < 2: continue
        hexpart = parts[1].split("  ")[0]
        try: b += [int(x, 16) for x in hexpart.split()]
        except ValueError: pass
    return b[:256] if len(b) >= 256 else None

order = ["idle1","load1","mode_a","mode_b","mode_c","idle2"]
snaps = {n: load(n) for n in order}
snaps = {k: v for k, v in snaps.items() if v}
names = list(snaps)
if not names:
    print("no snapshots found in", d); sys.exit()
print("snapshots:", ", ".join(names))
print("\nregisters that CHANGED (offset: per-snapshot values):")
hits = []
for off in range(256):
    vals = [snaps[n][off] for n in names]
    if len(set(vals)) > 1:
        hits.append((off, dict(zip(names, vals))))
        print(f"  0x{off:02X} ({off:3d}): " + "  ".join(f"{n}={snaps[n][off]:3d}" for n in names))
print("\nHEURISTICS:")
flagged = False
for off, v in hits:
    note = []
    if "idle1" in v and "load1" in v and v["load1"] > v["idle1"] + 8:
        note.append("↑ under load → TEMP or FAN-DUTY candidate")
    modes = [v[k] for k in ("mode_a","mode_b","mode_c") if k in v]
    if len(modes) >= 2 and len(set(modes)) > 1:
        note.append("changes with mode button → POWER-MODE candidate")
    if "idle2" in v and "load1" in v and v["load1"] > v.get("idle2", 0) + 8:
        note.append("high@load, low@idle2 → likely TEMP/FAN (tracks heat)")
    if note:
        flagged = True
        print(f"  0x{off:02X}: " + "; ".join(note))
if not flagged:
    print("  (nothing obvious — may need a hotter load or longer fan ramp; re-snap load1)")
PY
