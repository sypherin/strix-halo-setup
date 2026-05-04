# ComfyUI + Qwen-Image-2512 on Strix Halo (gfx1151)

What works, what doesn't, and the actual benchmark numbers as of May 2026.

## TL;DR

- **Working config**: GGUF Q6_K + Lightning 4-step LoRA via the `UnetLoaderGGUF` node + `--highvram` ComfyUI flag + TheROCk 7.13 nightly torch
- **Steady-state warm gen**: **36 seconds per 1024×1024 image** at full Qwen-Image-2512 quality (anatomy reliable)
- **Cold gen**: ~80-120s (model load)
- **All 4 services (llama-server, llama-vlm, comfyui, surya) coexist on the same Strix Halo without contention** — verified under load

## What does NOT work (and don't waste time trying)

### FP8 variant of Qwen-Image-2512 (`qwen_image_2512_fp8_e4m3fn.safetensors`)

The 20GB FP8 model crashes ComfyUI ~70-90s into model load with `SIGKILL` (exit status 137) and **no kernel OOM-killer log, no amdgpu error, no HIP exception in journal**. Reproducible across:

- ComfyUI 0.13.0 and 0.20.1
- All combinations of `--lowvram` / `--highvram` / `--cache-none`
- Multiple PyTorch HIP env vars
- 768×768 and 1024×1024 resolutions

A Medium-published benchmark from earlier in 2026 confirms: "encountered out-of-memory errors whether we set VRAM to 96GB or 64GB, making full-precision execution impossible." Use GGUF instead.

### `sage-attention` package

CUDA-only. No AMD/HIP build exists. Skip.

### Standard `flash-attn` pip install

Build fails on ROCm (no NVCC).

### `flash-attn` from ROCm fork (`ROCm/flash-attention` tridao branch)

Installs but pulls `aiter` as a sub-dependency. `aiter` JIT-compiles kernels on first import using `hipcc -mllvm -amdgpu-coerce-illegal-types=1` — this flag isn't supported by the kyuz0 image's hipcc. Result: ComfyUI crashes on startup. Rolled back, no damage.

### `--use-quad-cross-attention` flag

Tested vs default `--use-pytorch-cross-attention`. Neutral or slightly slower. Default PyTorch SDPA wins on this stack — its built-in Flash + mem-efficient + math backends are already enabled in the rocm7.13 nightly torch.

### `PYTORCH_HIP_ALLOC_CONF=:16:8:32GB` env var (from external strix guides)

That literal string crashes torch's tokenizer with `c10::Error: Index out of bounds in ConfigTokenizer`. Don't set it.

### `--cache-none` flag (kyuz0 default)

Forces model unload between gens. Means every gen is a cold load (~120s). Removed for `--highvram` which keeps the model resident → 36s warm.

## Working config — full recipe

### 1. systemd unit

See [`systemd/comfyui.service`](../systemd/comfyui.service). Key changes from kyuz0 default:

- Removed `--cache-none` (model now stays resident)
- Removed `--lowvram`, added `--highvram`
- Added env vars: `GPU_MAX_HEAP_SIZE=100`, `GPU_MAX_ALLOC_PERCENT=100`, `HIP_VISIBLE_DEVICES=0`, `AMD_LOG_LEVEL=0`
- `unset CUDA_VISIBLE_DEVICES` to avoid GPU hiding

### 2. Upgrade torch to TheROCk 7.13 nightly (optional but recommended)

```bash
podman exec strix-halo-comfyui /opt/venv/bin/pip install \
  --upgrade \
  --index-url https://rocm.nightlies.amd.com/v2/gfx1151/ \
  torch==2.11.0+rocm7.13.0a20260424 \
  torchvision==0.26.0+rocm7.13.0a20260424 \
  torchaudio==2.11.0+rocm7.13.0a20260424
```

The wheel is fully self-contained — installs `rocm-sdk-libraries-gfx1151` into the venv, does NOT touch host `/opt/rocm`. Safe alongside other ROCm services (llama-vlm etc.).

Snapshot the venv first if you want a rollback path:

```bash
podman exec strix-halo-comfyui cp -a /opt/venv /opt/venv.bak
```

Performance impact for our workload: neutral (35→36s warm). Worth doing for the newer infrastructure but don't expect a speedup until ROCm 7.3 ships gfx1151-optimized rocBLAS Tensile kernels (projected Q3 2026).

### 3. Download GGUF model + Lightning LoRA

```bash
# Q6_K variant (~16GB) — near-original quality, fits Strix Halo cleanly
podman exec strix-halo-comfyui /opt/venv/bin/hf download \
  unsloth/Qwen-Image-2512-GGUF \
  qwen-image-2512-Q6_K.gguf \
  --repo-type model \
  --local-dir ~/comfy-models/diffusion_models/

# Lightning 4-step LoRA — already standard in ComfyUI ecosystem
# https://huggingface.co/lightx2v/Qwen-Image-2512-Lightning
```

### 4. ComfyUI-GGUF custom node

Required to load `.gguf` files. Already present in kyuz0 image:

```bash
podman exec strix-halo-comfyui ls /opt/ComfyUI/custom_nodes/ | grep GGUF
# Should show: ComfyUI-GGUF
```

If missing:

```bash
podman exec strix-halo-comfyui bash -c \
  'cd /opt/ComfyUI/custom_nodes && git clone https://github.com/city96/ComfyUI-GGUF.git'
```

Then restart ComfyUI.

### 5. Workflow template

API-format JSON: see [`workflows/qwen-image-2512-gguf-lightning.json`](../workflows/qwen-image-2512-gguf-lightning.json). Submit via:

```bash
curl -X POST http://localhost:7860/prompt \
  -H 'Content-Type: application/json' \
  -d @workflows/qwen-image-2512-gguf-lightning.json
```

Or in the GUI: drag-drop the JSON, swap the prompt, click Queue Prompt.

Critical node settings:
- `UnetLoaderGGUF` (NOT `UNETLoader`) → `qwen-image-2512-Q6_K.gguf`
- `LoraLoaderModelOnly` → `Qwen-Image-2512-Lightning-4steps-V1.0-fp32.safetensors`, strength 1.0
- `ModelSamplingAuraFlow` → shift 3.1
- `KSampler` → 4 steps, cfg 1.0, sampler `euler`, scheduler `simple`, denoise 1.0
- `EmptySD3LatentImage` → 1024×1024

## Benchmarks

All measured with the Working config above, on Sixunited AXB35 (Ryzen AI MAX+ 395, Radeon 8060S, 96GB VGM unified memory). Three back-to-back warm gens, model resident.

| Config | Time | Quality |
|--------|------|---------|
| **Lightning 4-step + Q6 + 1024×1024** | **36s warm** | reference (anatomy reliable) |
| Lightning 4-step + Q6 cold gen | ~80-120s | (first gen after restart) |
| Lightning 4-step + Q4 + 1024×1024 | 42s warm | reference (Q4 surprisingly slower than Q6) |
| Wuli 2-step Turbo LoRA + Q4 + 1024×1024 | 21s warm | **anatomy lottery** (~30% missing details) |
| Lightning 4-step + Q6 + 768×768 | ~30s warm | reference, smaller image |
| Wuli 2-step + Q4 + 768×768 | ~15s warm | preview only |

### Concurrent service health

During heavy ComfyUI generation, simultaneously running:

- `llama-server` (Vulkan, Qwen3.6-35B-A3B at 128k context, port 8001)
- `llama-vlm` (ROCm, Qwen3-VL-32B, port 8080)
- `surya-server` (ROCm, layout/OCR for production OCR pipeline, port 8090, runs in same container as ComfyUI)

All four stayed responsive (HTTP 200) throughout repeated generation batteries. Combined GTT memory ~80GB / 124GB available with thin headroom; system RAM swap is tight but stable.

## Anatomy regression with Wuli 2-step LoRA

The `Wuli-art/Qwen-Image-2512-Turbo-LoRA-2-Steps` LoRA is 1.5x faster than the standard Lightning 4-step LoRA but produces unreliable anatomy at 2 steps. In our cat-on-table prompt: ~1/3 generations missing tails or other details vs Lightning 4-step which is reliable across seeds.

Verified by running the same prompt at 2 / 3 / 4 steps with the Wuli LoRA on a "bad" seed: the missing tail persists at all step counts with Wuli. Switching back to Lightning 4-step on the same seed: tail returns. So the regression is in the Wuli LoRA itself, not the step count.

**Use Wuli only for variation hunting where you'll regenerate the keeper.** For final/hero assets, use Lightning 4-step.

## Hardware ceiling

For full-quality 1024×1024 Qwen-Image generation on Strix Halo (May 2026): **35-36s warm is the ceiling.**

Reaching faster requires:
- Wait for ROCm 7.3 stable (Q3 2026, gfx1151 rocBLAS Tensile kernels — projected ~20-25s)
- Add a discrete GPU (used RTX 3090 ~8s/image, end-to-end)
- Accept lower quality (Wuli 2-step at 21s with anatomy lottery)

## See also

- [`systemd/comfyui.service`](../systemd/comfyui.service) — production systemd unit
- [`workflows/qwen-image-2512-gguf-lightning.json`](../workflows/qwen-image-2512-gguf-lightning.json) — API-format workflow template
- [kyuz0/amd-strix-halo-comfyui-toolboxes](https://github.com/kyuz0/amd-strix-halo-comfyui-toolboxes) — base container image
- [unsloth/Qwen-Image-2512-GGUF](https://huggingface.co/unsloth/Qwen-Image-2512-GGUF) — GGUF quantizations
- [city96/ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) — GGUF loader nodes
- [lightx2v/Qwen-Image-2512-Lightning](https://huggingface.co/lightx2v/Qwen-Image-2512-Lightning) — Lightning LoRA
