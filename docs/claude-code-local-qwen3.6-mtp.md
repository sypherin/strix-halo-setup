# Claude Code on local Qwen3.6-35B-A3B (Strix Halo, native MTP, 256k)

Run the **Claude Code CLI against a local Qwen3.6-35B-A3B** model on the Strix Halo —
fully offline, zero API cost, 256k context — for real software development on large
codebases. Built + verified 2026-07-10.

## TL;DR — how to run it

```bash
ccr code                     # from any project dir → Claude Code driving local Qwen3.6
ccr code -p "refactor foo"   # one-shot / headless
ccr status                   # is the router up?
ccr restart                  # after any model/config change
```

The router (ccr) and `llama-server` run as background services, so day-to-day it's just `ccr code`.

## The stack

```
Claude Code CLI  ──►  claude-code-router (ccr, :3456)  ──►  llama-server (:8001)
                                                             Qwen3.6-35B-A3B MTP, Vulkan/RADV, 256k
```

- **llama.cpp** — fresh upstream build, Vulkan backend (gfx1151 / Radeon 8060S).
- **claude-code-router (ccr)** — bridges Claude Code's Anthropic API surface to the local OpenAI-compatible endpoint.
- **Model** — unsloth `Qwen3.6-35B-A3B-MTP-GGUF` (UD-Q4_K_XL) with **native multi-token-prediction** speculative decoding.

## Full setup from scratch

### 1. Build llama.cpp (latest, Vulkan)

```bash
git clone --depth 1 https://github.com/ggml-org/llama.cpp ~/llama.cpp
cd ~/llama.cpp
cmake -B build -G Ninja -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON
cmake --build build -j16 --target llama-server
```

- Build deps: `glslc`, `cmake`, `ninja`, Vulkan headers (mesa 1.4.x).
- Output `build/bin/llama-server` is a thin launcher; it finds `libllama-server-impl.so` etc. via **rpath** — no `LD_LIBRARY_PATH` needed.
- **Verified build:** ggml-org/llama.cpp @ `fb30ba9` (2026-07-09), mesa Vulkan **1.4.341**, device `AMD Radeon 8060S (RADV GFX1151)`.
- Native MTP flag exposed: `--spec-type draft-mtp` (older unsloth docs call it `--spec-type mtp`; upstream renamed it).

### 2. Download the MTP model

```bash
export HF_HUB_ENABLE_HF_TRANSFER=1
hf download unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
  --include "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
  --local-dir ~/models/qwen3.6-mtp
```

- ~22.85 GB. The **MTP layers are grafted into this GGUF** — that's what enables native speculative decoding (vs a separate draft model, which does NOT work well here — see benchmarks).
- Higher-quality quants exist in the same repo: `UD-Q5_K_XL`, `UD-Q6`, `Q8_0`.

### 3. systemd service — `systemd/llama-server.service`

Key flags:

| flag | why |
|------|-----|
| `--spec-type draft-mtp --spec-draft-n-max 3` | **native MTP speculative decoding** — the speedup |
| `--ctx-size 262144` | full **256k** native context (model is trained to 262144) |
| `-ngl 99` | all layers on GPU |
| `-fa 1` | flash attention |
| `-ctk q8_0 -ctv q8_0` | q8 KV cache — lean; GQA keeps KV tiny even at 256k |
| `--reasoning-budget 500 --reasoning-format auto` | hybrid-thinking; reasoning → `reasoning_content`, `content` stays clean |
| `Environment=GGML_VK_PREFER_HOST_MEMORY=ON` | Strix unified-memory tuning |

```bash
systemctl --user daemon-reload
systemctl --user enable --now llama-server.service
```

### 4. ccr config — `configs/claude-code-router.config.json`

(API keys redacted — local :8001 needs none.)

- Provider `local-qwen` → `http://127.0.0.1:8001/v1/chat/completions`
- `Router.default` (and background/think/longContext/webSearch) → `local-qwen,Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf`
- Lives at `~/.claude-code-router/config.json`. After edits: **`ccr restart`**.

### 5. Switch models — `bin/strix-llm-switch.sh`

```bash
~/bin/strix-llm-switch.sh qwen    # → Qwen3.6 MTP on :8001  (llama-server.service)
~/bin/strix-llm-switch.sh gemma   # → a second model on :8001 (llama-server-gemma.service)
```

Writes `~/.config/strix-llm-unit`. If you run a liveness watchdog for :8001, have it read
that file so it revives the currently-selected unit and never fights a swap. The inactive
model's unit is stopped + disabled.

## Benchmarks (measured, this box, coding prompts)

| config | tok/s (gen) | notes |
|--------|------------:|-------|
| Q8, no MTP, old June-5 fork build | ~42 | prior build |
| Q4_K_XL, no MTP, fresh upstream build | ~61 | fresh Vulkan build alone helps |
| Q4_K_XL + classic separate 0.8B draft | ~27 | ❌ **BACKFIRED** — mismatched draft, ~20% acceptance |
| **Q4_K_XL + native MTP (`draft-mtp`)** | **~75–86** | ✅ **THE config** — draft acceptance **65–80%** |

- At 256k context: **74–80 t/s**, no penalty. Draft acceptance ~0.80 on code.
- Community reference: ~101 t/s on Qwen3.6 MTP with leaner `IQ4_XS` + tuned `n-max`. Q4_K_XL trades a little speed for coding quality.
- End-to-end verified: `ccr code -p` (real CLI) → local Qwen3.6 → correct working code.

## Memory (256k context)

- **GPU GTT ≈ 30 GB** of a ~**80 GB** safe ceiling (>80 GB risks a Strix freeze).
- Qwen3.6's GQA makes the KV cache tiny — an 8k-token prompt grew memory by **~5 MB**.

## Thinking-token caveat (for OpenAI-API apps that hit :8001, not Claude Code)

Qwen3.6 is **hybrid-thinking**. With `--reasoning-format auto` the reasoning goes to
`reasoning_content` and `content` stays clean. But:

- **Small `max_tokens` + thinking-on → reasoning eats the budget → empty `content`.**
- Fixes: send `chat_template_kwargs: {"enable_thinking": false}` for direct-output callers,
  **or** give a large `max_tokens` (extraction pipelines using 8–16k budgets are safe).
- Claude Code sends large budgets → always gets clean answers.
- If you swap a non-thinking model (e.g. Gemma) → Qwen3.6 on a shared :8001, audit any
  small-`max_tokens` callers first — that's the only place the swap can bite.

## Files in this repo

- `systemd/llama-server.service` — the live service (Qwen3.6 MTP, 256k, Vulkan).
- `bin/strix-llm-switch.sh` — model toggle via `~/.config/strix-llm-unit`.
- `configs/claude-code-router.config.json` — ccr config (secrets redacted).
- `tools/cc-qwen-vs-opus.sh` — head-to-head test harness (local Qwen3.6 vs Opus).

## Reasoning budget — how deeply it thinks (updated 2026-07-11)

Qwen3.6 is hybrid-thinking: it can emit a hidden `<think>…</think>` block before answering.
Whether it thinks, and **how long**, is decided per request — not a fixed model property.

**Two switches:**
- `chat_template_kwargs: {"enable_thinking": true/false}` — the API field (what direct callers set).
- `/think` or `/no_think` **in the message text** — Qwen's soft switch; works through `--jinja`.
  This is how you get reasoning in **ccr**: ccr forwards your message untouched, so just type
  `/think` in your prompt (there's no way to set the API field through ccr). `/no_think` disables it.

**How MUCH it thinks = `--reasoning-budget` (server launch flag):**
- Values: `-1` = unlimited · `0` = thinking off · `N` = an N-token cap on reasoning.
- **We now run `4096` (was `500`).** Set in `systemd/llama-server.service`; change it there +
  `systemctl --user restart llama-server.service`.
- ⚠ **Per-request budget is NOT honored on this llama.cpp build** — tested `reasoning_budget: 50`
  in the request body, still got ~384 reasoning tokens. So the global flag is the only knob.

**Why 4096 (not 500):** 500 was starving debugging — the model reasoned only ~420 tokens and hit
the cap. Empirically (2026-07-11): asked to self-debug a 3D three.js build from its own error
messages, at **budget 500 + single-shot it thrashed** (rewrote the whole file 3× and never fixed a
one-line bug); at **budget 4096 + an agentic loop it self-fixed to zero errors in 2 rounds**, using
~2,800 reasoning tokens per round. 4096 is also the Qwen3.6-MTP reasoning-eval sweet spot for
coding/debug (range 4k–8k); small-active models (this is 3B-active) benefit most from more budget.

**Does raising it slow everything? No.** The budget is a *cap, not a floor* — a request only reasons
as long as it needs. Requests with thinking **off** are unaffected — and **neo/deneb sends
`enable_thinking:false`** (see `~/neo-assistant/src/llm.py`), so it does zero thinking and the bigger
budget can't touch it. Only requests that opt into thinking (ccr `/think`, extraction pipelines)
reason deeper and thus take more wall-clock; per-token speed (~85 t/s) is unchanged.

Refs: Qwen3 thinking-budget docs · Qwen3.6-MTP-pi-reasoning (4096/8192) · llama.cpp
`common/reasoning-budget.cpp` · thinking-mode-pitfalls-in-agentic-workflows.
