# Qwen3.8-Flash-Next on Strix Halo (EngramHalo): the stable config, and why the crash wasn't parallel or the quant

Qwen3.8-Flash-Next is a ~125B-A6B MoE with a ~51B per-layer-embedding "engram" table. On a
Strix Halo (Ryzen AI MAX+ 395, gfx1151, 128 GB) the way to fit it is the **EngramHalo** llama.cpp
fork (kyuz0 `amd-strix-halo-toolboxes:rocm-10.0-engramhalo`), which can keep the engram
SSD-backed via a lazy tensor read. This page records the config that is **stable**, and a night of
crashes that got misdiagnosed twice before the real cause — so you don't repeat it.

## TL;DR

- **Serve in RAM mode (`-lm none`), not the SSD lazy-read.** RAM mode makes the engram fully
  resident (~30 GiB headroom left on 128 GB with UD-IQ4_XS), and is *faster* than the SSD path
  (no per-token engram paging). ~28 tok/s warm.
- ⛔ **`-lm mmap --lazy-mode on` (SSD lazy-read) SIGSEGVs under memory pressure** — EngramHalo.cpp
  **issue #1**. In practice it crashed the server every ~5–10 min *regardless of quant,
  `--parallel`, or spec-decode setting, and even while idle*.
- ⛔ **`--parallel > 1` is not usable** for this model on this build: multi-slot Qwen3-Next is
  young upstream — needs the #25992 host-buffer patch and **no MTP sidecar**, and still carries
  open crash/coherency bugs (ggml-org/llama.cpp #21909, #20222, #27994).
- **Diagnosis reflex:** a silent `status=139` (SIGSEGV) with a **clean `journalctl -k`** (no
  `amdgpu` / `GCVM_L2` page fault) is a **CPU segfault inside the build**, not a GPU or
  GTT-memory fault. GTT sitting ~100/112 GiB is normal-tight for this model and was a red herring.

## The stable config (RAM mode)

```bash
toolbox run --container engramhalo \
  env ROCBLAS_USE_HIPBLASLT=1 \
  llama-server -m Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  --mmproj mmproj-F16.gguf \
  -ngl 999 -fa on -ctk q8_0 -ctv q8_0 \
  -lm none -c 131072 -b 8192 -ub 2048 -t 4 --parallel 1 --jinja --no-webui \
  -md mtp-Qwen3.8-Flash-Next-Q8_0.gguf \
  --spec-type draft-mtp,ngram-mod --spec-draft-n-max 4
```

- `-lm none` = engram fully in RAM, no SSD lazy-read, so it *cannot* hit issue #1.
- Fits at `-c 131072` with **UD-IQ4_XS** (~84 GB weights + resident engram). The larger
  **UD-Q4_K_XL** leaves too little headroom in RAM mode — use IQ4_XS.
- MTP (`-md … --spec-type draft-mtp,ngram-mod`) is validated single-slot up to a ~164K slot, so it
  is fine at `-c 131072`.
- The first request after load is cold (compute graph + n-gram/MTP speculative cache warm up);
  steady state is ~28 tok/s. A cold first-token reading of ~20 tok/s is not a regression.

## The crash, and the two wrong turns

Symptom: `llama-server` exits **139** (SIGSEGV) every ~5–10 min, silently — no GGML assert, no
error line — on every config tried, **including at idle**.

- **Wrong turn 1 — "it's `--parallel 2`":** dropping to `--parallel 1` still crashed.
- **Wrong turn 2 — "it's the IQ4_XS quant":** switching to Q4_K_XL crashed too.
- What broke it open: **`journalctl -k` was clean at every crash.** No GPU VM fault → not the GPU,
  not the GTT ceiling. A silent CPU segfault, on every config, even idle → a bug in the build's
  code — and the one flag common to *all* the crashing configs was `-lm mmap --lazy-mode on`.
  That path is the fork's known **issue #1** (segfault under memory pressure). Switching to
  `-lm none` fixed it.

The general lesson: **a bounded stress test that passes is not proof of stability for an
intermittent fault.** A 4-round concurrent harness passed twice on configs that then crashed
minutes later under real load. Only a sustained real-load soak — plus reading `journalctl -k`
instead of guessing — found the cause.

## Concurrency

Not available here. The EngramHalo docs' multi-slot recipe (`--parallel 4`) requires the #25992
host-buffer patch (`Dockerfile.rocm-7.14`) and **no MTP**, and even then Qwen3-Next multi-slot
has open upstream bugs. For concurrent serving, run a second single-slot instance behind a
queue/router rather than `-np > 1`.
