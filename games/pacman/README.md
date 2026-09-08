# Pac-Man — single-file HTML5 build

A complete, polished, playable Pac-Man clone in **one self-contained `index.html`**
(inline CSS + JS, no external assets, no libraries, no build step). Open it in any
browser and play.

- **Grid maze:** 28 × 31 tiles, 20px tiles, 560 × 620 canvas.
- **Pac-Man:** continuous cell-to-cell movement, buffered direction changes
  (`nextDir` applied at the next walkable center), immediate mid-tile reverse.
- **4 ghosts, classic personalities:**
  - Blinky — direct chase
  - Pinky — ambush 4 tiles ahead
  - Inky — Blinky-reflection flank
  - Clyde — chases when far, scatters when close
- **Ghost modes:** house → scatter → chase → fright → eyes (eaten ghosts return to
  the house and respawn).
- **Power pellets** (4 corners) trigger a fright window; eaten ghosts score a
  200 / 400 / 800 / 1600 combo chain.
- **Side tunnel** wrap on the middle row (exit left, re-enter right, and vice versa).
- **Scoring, 3 lives, level progression, high-score** (localStorage), Web Audio
  synth SFX, keyboard (arrows / WASD) + on-screen touch d-pad.

## How to run

```sh
# just open it
xdg-open index.html        # or any browser
```

## Session work log — Qwen Code CLI + Qwen 2.8 27B

This build was produced and debugged in a single Qwen Code CLI session running
**Qwen 2.8 27B** (local). The session covered the initial build plus a bug-fix
pass driven by three reported defects.

### Defects reported and fixed

1. **Ghosts walked through walls and never chased.**
   - *Root cause:* movement used a center-snap check
     `Math.abs(x - center.x) < 0.01` to decide "am I at a tile center, so re-pick a
     direction?". That only ever fired for **integer** speeds. Pac-Man's speed is
     2.0 (20px / 2.0 = 10 frames per tile → lands exactly on centers), but the
     ghosts' speed is 1.8 (20 / 1.8 = 11.11 frames per tile → **never** lands within
     0.01 of a center). So the ghosts' direction was decided once at spawn and never
     again: they ran in a straight line, clipped through walls, and could not chase.
   - *Fix:* rewrote the shared `stepEntity()` mover. The target tile-center is now
     computed **dynamically** from the entity's position relative to its current
     tile center, and each step is **clamped** so the entity lands *exactly* on a
     center at **any** speed. Direction re-decision and wall checks therefore fire
     correctly for the 1.8px ghosts (and any future speed).

2. **Pac-Man vanished in the side tunnels and never came out the other side.**
   - *Fix:* the same rewrite made the tunnel wrap correct — when an entity crosses
     the left/right edge on the middle row its x is wrapped by the canvas width, and
     the dynamic target keeps it gliding smoothly out the far side.

3. **Walls not rendering (earlier in the session).**
   - *Root cause:* Canvas 2D does not resolve CSS `var(--…)` custom properties, so
     every `fillStyle = 'var(--wall)'` silently produced nothing.
   - *Fix:* introduced a literal-hex color constant `C` and replaced all canvas
     `var(--…)` references with `C.*`.

### Verification

A headless Node harness (Proxy-based canvas-ctx stub + DOM / localStorage /
AudioContext stubs) runs the real game loop and asserts on actual entity state.
All six regression checks pass:

| # | Check | Result |
|---|-------|--------|
| T1  | Ghosts change direction (turn / chase) | PASS |
| T2  | Ghosts never land on a wall tile | PASS (wallHits = 0) |
| T2b | Pac-Man never lands on a wall tile | PASS |
| T3  | Pac-Man wraps left tunnel → right side | PASS |
| T3b | Pac-Man wraps right tunnel → left side | PASS |
| T4  | Blinky closes the distance to Pac-Man (chase works) | PASS (Pac-Man caught) |

Visual verification: headless Chrome screenshots inspected with a local VLM
confirmed the maze renders, Pac-Man and all four ghosts sit in corridors (none
overlapping walls), and dots / power pellets are drawn.

### Files

- `index.html` — the game (single file, ~1000 lines).
