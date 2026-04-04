# Strix Halo Local AI Setup

Local LLM/VLM + image/video generation + NPU inference for AMD Strix Halo APU (Ryzen AI MAX+ 395, Radeon 8060S iGPU, XDNA2 NPU) with 96GB unified VRAM.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  GPU (Vulkan RADV — 96GB unified VRAM)                          │
│  ├─ llama-server (turboquant build)     port 8001               │
│  │  └─ Qwen3.5-122B-A10B (~22 t/s gen, ~393 t/s prompt)        │
│  ├─ ComfyUI (ROCm toolbox)             port 7860               │
│  │  └─ Image/video gen (Wan 2.2, HunyuanVideo, Qwen Image)     │
│  └─ llama-vlm-bom (ROCm toolbox)       port 8080               │
│     └─ Qwen3-VL-32B (vision/BOM extraction)                    │
│                                                                  │
│  NPU (XDNA2 — 51 TOPS, 47μs latency)                           │
│  └─ FastFlowLM                          port 52625              │
│     └─ Small models: Whisper, embeddings, Qwen3.5:4b            │
└──────────────────────────────────────────────────────────────────┘
```

All GPU services run as **systemd user services** with auto-start on boot.

## Hardware

| Component | Details |
|-----------|---------|
| Board | Sixunited AXB35 (BeyondMax Series) |
| CPU | AMD Ryzen AI MAX+ 395 (32 threads) |
| GPU | Radeon 8060S (RDNA 3.5, gfx1151) |
| VRAM | 96GB unified (VGM BIOS setting) |
| NPU | XDNA2 aie2p 6x8 (PCI c7:00.1, 1022:17f0 rev 11) |
| RAM | ~31GB visible to Linux (rest is GPU VRAM) |
| BIOS | AMI v1.07 |

## Software stack

| Component | Version | Notes |
|-----------|---------|-------|
| Kernel | 7.0.0-rc6 (vanilla) | COPR `@kernel-vanilla/mainline-wo-mergew` |
| Mesa | 25.3.6 | Vulkan RADV driver |
| llama.cpp | turboquant build (8793) | Custom Vulkan build from `~/llama-cpp-turboquant` |
| ROCm | 7.2 (kyuz0 toolbox) | For VLM + ComfyUI containers |
| XRT | 2.23.0 | NPU runtime, built from `~/xdna-driver` |
| amdxdna | 2.23.0 (DKMS) | NPU kernel module |
| FastFlowLM | v0.9.36 | NPU inference server |

## Quick start

```bash
git clone https://github.com/sypherin/strix-halo-setup.git
cd strix-halo-setup
chmod +x setup.sh bin/*.sh patches/*.sh
./setup.sh
systemctl --user start llama-server comfyui
```

For NPU setup, see [NPU Setup](#npu-setup) below.

## Performance benchmarks

### LLM inference (Qwen3.5-122B-A10B UD-Q4_K_XL)

Tested on kernel 7.0-rc6, Mesa 25.3.6, Vulkan RADV, turboquant build 8793.

| Metric | Value | Notes |
|--------|-------|-------|
| Prompt processing (pp) | **393 t/s** | ~2K token prompt |
| Token generation (tg) | **22 t/s** | Stable across runs |
| Time to first token | **~430ms** | Short prompts |
| Context size | 65536 | KV cache: q8_0 |

#### Kernel comparison

| Metric | Kernel 6.19.9 | Kernel 7.0-rc6 | Change |
|--------|--------------|----------------|--------|
| pp | 287-351 t/s | 393 t/s | +12-37% |
| tg | 22-23 t/s | 22 t/s | No change |

Kernel 7.0 significantly improves prompt processing via RADV/Vulkan improvements, but token generation is memory-bandwidth bound and unchanged.

#### Optimization history

| Setting | Tested values | Winner | Notes |
|---------|--------------|--------|-------|
| `--ubatch-size` | 512, 1024, 2048 | **1024** | pp 320 vs 266 vs 320, diminishing returns at 2048 |
| `--kv-unified` | on, off | **off** | Hurt pp, broke prompt caching, no tg benefit |
| `-ctk`/`-ctv` | turbo2, q8_0 | **q8_0** | turbo2 not supported on Vulkan (SET_ROWS op missing) |
| `-fa` | on, off | **on** | Required for good performance on Strix Halo |

## Services

| Service | Port | Backend | Startup | Description |
|---------|------|---------|---------|-------------|
| `llama-server` | 8001 | Vulkan | auto | LLM inference (turboquant build 8793) |
| `comfyui` | 7860 | ROCm | auto | Image/video gen (kyuz0 toolbox container) |
| `llama-vlm-bom` | 8080 | ROCm | auto | Vision LLM (Qwen3-VL-32B, kyuz0 ROCm 7.2 toolbox) |
| `fastflowlm` | 52625 | NPU | auto | Small model inference (Qwen3.5:4b, Whisper) |
| `lemonade` | 8000 | Vulkan | manual | Web UI + sd-cpp (optional) |

### Managing services

```bash
# Status
systemctl --user status llama-server comfyui llama-vlm-bom

# Start/stop
systemctl --user start llama-server
systemctl --user stop llama-server

# Logs
journalctl --user -u llama-server -f

# Health check
curl http://localhost:8001/health
```

## Kernel boot parameters

Required for optimal Strix Halo unified memory performance:

```
iommu=pt ttm.pages_limit=31457280
```

- `iommu=pt` — reduces overhead for iGPU unified memory access
- `ttm.pages_limit=31457280` — caps pinned memory for GPU allocation

Optional (recommended by kyuz0):
```
amdgpu.gttsize=126976
```

Set via `grubby` or `/etc/default/grub`.

## Containers (toolboxes)

| Container | Image | Status | Purpose |
|-----------|-------|--------|---------|
| `llama-rocm-7.2` | `kyuz0/amd-strix-halo-toolboxes:rocm-7.2` | running | ROCm LLM inference (VLM) |
| `strix-halo-comfyui` | `kyuz0/amd-strix-halo-comfyui:latest` | running | ComfyUI image/video gen |
| `strix-halo-image-video` | `kyuz0/amd-strix-halo-image-video:latest` | available | Qwen Image Studio + Wan 2.2 |
| `llama-vulkan-radv` | `kyuz0/amd-strix-halo-toolboxes:vulkan-radv` | available | Vulkan LLM (backup) |

### Available kyuz0 toolboxes

| Toolbox | Docker Tag | Purpose |
|---------|-----------|---------|
| Vulkan RADV | `kyuz0/amd-strix-halo-toolboxes:vulkan-radv` | llama.cpp Vulkan (most stable) |
| ROCm 7.2 | `kyuz0/amd-strix-halo-toolboxes:rocm-7.2` | llama.cpp ROCm (long context) |
| ComfyUI | `kyuz0/amd-strix-halo-comfyui:latest` | Image/video gen (ROCm TheRock) |
| Image/Video | `kyuz0/amd-strix-halo-image-video:latest` | Qwen Image + Wan 2.2 + ComfyUI |
| vLLM | `kyuz0/vllm-therock-gfx1151:latest` | vLLM serving (ROCm TheRock) |
| Finetuning | `kyuz0/amd-strix-halo-llm-finetuning:latest` | LoRA/QLoRA training (ROCm) |
| Voice | `kyuz0/amd-strix-halo-voice:latest` | VibeVoice TTS + voice cloning |

## NPU Setup

The XDNA2 NPU requires an out-of-tree driver build — the kernel's built-in amdxdna v0.6.0 has a version mismatch with newer XRT. The COPR `xanderlent/amd-npu-driver` packages (April 2025) are also outdated.

### Build and install from source

```bash
# Clone AMD's xdna-driver repo
git clone --depth 1 https://github.com/amd/xdna-driver.git ~/xdna-driver
cd ~/xdna-driver
git submodule update --init --recursive

# Install dependencies
sudo dnf install -y ninja-build jq

# Build XRT base + NPU packages
cd xrt/build
bash build.sh -npu -opt
sudo rpm -Uvh --force Release/xrt_*-base.rpm Release/xrt_*-npu.rpm

# Build and install the xdna driver plugin (includes DKMS kernel module)
cd ../../build
bash build.sh -release -install_prefix /opt/xilinx/xrt
sudo rpm -Uvh --force Release/xrt_plugin.*-amdxdna.rpm

# Verify NPU is detected
source /opt/xilinx/xrt/setup.sh
xrt-smi examine
# Should show: RyzenAI-npu5, aie2p, 6x8

# Validate NPU compute
xrt-smi validate
# GEMM and latency tests should pass
```

### NPU validation results

```
Test 1: gemm        → PASSED (51.0 TOPS)
Test 2: latency     → PASSED (47.0 μs average)
Test 3: throughput  → FAILED (runlist abort — known issue, non-critical)
```

### Key NPU details

- **Driver**: amdxdna v2.23.0 (DKMS, built from `amd/xdna-driver` main branch)
- **XRT**: v2.23.0 (built from submodule, installed at `/opt/xilinx/xrt/`)
- **Firmware**: `npu.sbin.1.0.0.166` at `/lib/firmware/amdnpu/17f0_11/`
- **Device**: `[0000:c7:00.1]` RyzenAI-npu5, aie2p architecture, 6x8 topology
- **memlock**: unlimited (`/etc/security/limits.d/99-amdxdna.conf`)
- **BIOS note**: No NPU/IPU toggle in Sixunited AXB35 BIOS — NPU is enabled by default

### NPU use cases

The NPU (55 TOPS INT8) is best for small always-on models, freeing the GPU for large models:

| Use Case | Tool | Performance |
|----------|------|-------------|
| Small LLM (1-4B) | FastFlowLM | 28-89 tok/s |
| Speech recognition | Whisper (via Lemonade) | Real-time |
| Embeddings | ONNX models | Low latency |

## Critical configuration notes

### --mmap is REQUIRED for Vulkan (do NOT use --no-mmap)

Strix Halo has 96GB unified memory shared between CPU and GPU, but Linux only sees ~31GB as system RAM. Using `--no-mmap` forces the entire model (72GB for Qwen3.5-122B) into system RAM, causing:
- All 31GB RAM consumed + swap thrashing
- System becomes unusable

With `--mmap`, the Vulkan driver maps model weights directly into unified VRAM. System RAM stays at ~6GB used.

### --no-mmap is REQUIRED for ROCm (opposite of Vulkan!)

ROCm toolbox containers use `--no-mmap` because ROCm's mmap path above 64GB is very slow on gfx1151. The GPU has direct access to system memory in ROCm mode, so `--no-mmap` loads into GPU-accessible memory correctly.

ComfyUI also requires `--disable-mmap --cache-none --bf16-vae` for the same reason.

### FP8 is broken on gfx1151 — always use BF16

FP8 is a **software limitation** on Strix Halo (RDNA 3.5). Always use BF16 models for image/video generation.

## Why Vulkan for LLM? Why ROCm for image gen?

**LLM inference**: ROCm doesn't reliably detect gfx1151 for all workloads. Vulkan via RADV works perfectly and uses the full 96GB unified VRAM. The custom turboquant build gives the best LLM performance.

**Image/video generation**: ComfyUI and PyTorch-based pipelines require ROCm. The kyuz0 toolbox containers include patched ROCm (TheRock nightlies) that work on gfx1151 with `HSA_OVERRIDE_GFX_VERSION=11.5.1`.

| | Vulkan (RADV) | ROCm (kyuz0 toolbox) |
|---|---|---|
| LLM (llama.cpp) | **~22 t/s gen, ~393 t/s pp** | ~21 t/s gen, ~268 t/s pp |
| Image gen (ComfyUI) | N/A | ~198 it/s |
| Stability | Excellent | Good (needs toolbox) |

## Models

### LLM (llama-server on port 8001)

| Model | Type | Active Params | Quant | Speed | Use case |
|-------|------|---------------|-------|-------|----------|
| Qwen3.5-122B-A10B | MoE | 10B | UD-Q4_K_XL | ~22 t/s gen, ~393 t/s pp | Default, SOTA quality |
| Qwen3-30B-A3B | MoE | 3B | — | ~57 t/s | Fast chat, coding |

To switch models, update the `-m` path in `llama-server.service` and restart:
```bash
systemctl --user restart llama-server
```

### VLM (llama-vlm-bom on port 8080)

| Model | Type | Params | Backend | Use case |
|-------|------|--------|---------|----------|
| Qwen3-VL-32B | Dense | 32B | ROCm 7.2 | Vision, BOM extraction |

### Image/Video Generation (ComfyUI on port 7860)

Toolbox: `kyuz0/amd-strix-halo-comfyui:latest` (ROCm TheRock nightlies)

| Workflow | Type | Notes |
|----------|------|-------|
| HunyuanVideo 1.5 | I2V / T2V | 4-step LoRA, 720p |
| Qwen Image 2512 | T2I | Must use BF16 (not FP8) |
| Qwen Image Edit | Image Editing | Lightning LoRA |
| Wan 2.2 | I2V / T2V | 14B model with 4-step Lightning LoRA |

## Building llama.cpp (turboquant Vulkan)

The current LLM server uses a custom turboquant build for better MoE quantization:

```bash
cd ~/llama-cpp-turboquant
git pull
mkdir -p build && cd build
cmake .. -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release -j$(nproc)

# Update service
systemctl --user restart llama-server
curl http://localhost:8001/health  # wait for model to load (~35s)
```

## Structure

```
├── setup.sh                              # Main setup script
├── systemd/
│   ├── llama-server.service              # LLM server (Vulkan turboquant, auto-enabled)
│   ├── llama-vlm-bom.service             # Vision LLM server (ROCm toolbox, auto-enabled)
│   ├── comfyui.service                   # ComfyUI (ROCm toolbox, auto-enabled)
│   └── lemonade.service                  # Lemonade router (optional, disabled by default)
├── bin/
│   ├── llama-server-wrapper.sh           # LD_LIBRARY_PATH wrapper for Vulkan binary
│   └── sd-server-wrapper.sh              # LD_LIBRARY_PATH wrapper for sd-cpp binary
├── patches/
│   ├── lemonade-provider-reasoning.patch # VS Code extension patches (human-readable)
│   └── apply-lemonade-patches.sh         # Auto-apply patches
└── vscode/
    └── continue-config.yaml              # Continue extension config
```

## Build history

| Component | Version | Date | Notes |
|-----------|---------|------|-------|
| llama.cpp | turboquant 8793 (custom Vulkan) | 2026-04-03 | 393 t/s pp, 22 t/s tg |
| llama-server | b8461 (kyuz0 Vulkan RADV) | 2026-03 | 351 t/s pp, 19 t/s tg (replaced) |
| llama-server | b8299 (official release) | 2026-03-13 | +40% prompt speed over b8119 |
| llama-server | b8119 (kyuz0 custom) | 2026-02 | Initial build |
| Kernel | 7.0.0-rc6 (vanilla) | 2026-04-04 | +12-37% pp over 6.19.9 |
| Kernel | 6.19.9 (Fedora 43) | 2026-03 | Previous stable |
| XRT | 2.23.0 | 2026-03-22 | Built from amd/xdna-driver submodule |
| amdxdna driver | 2.23.0 (DKMS) | 2026-03-22 | Out-of-tree, replaces kernel v0.6.0 |
| NPU firmware | 1.0.0.166 | 2026-03 | Protocol v6.x |

## Troubleshooting

### System is laggy when model is loaded
Check if `--no-mmap` is set (it shouldn't be for Vulkan):
```bash
systemctl --user cat llama-server | grep mmap
```
Must show `--mmap`, not `--no-mmap`. See [critical notes](#--mmap-is-required-for-vulkan-do-not-use---no-mmap).

### llama-server fails to start
```bash
journalctl --user -u llama-server --no-pager -n 50
```
Common causes:
- **"no usable GPU found"** — Vulkan backend libs missing. Check build output.
- **Model path changed** — update `-m` in service file
- **Esuna not mounted** — check `mount | grep Esuna`

### NPU not detected by xrt-smi
1. Check if DKMS module is loaded: `lsmod | grep amdxdna`
2. Check for errors: `journalctl -k -b | grep amdxdna`
3. Verify device: `ls /dev/accel/` (should show `accel0`)
4. If "0 devices found" but accel0 exists → XRT/driver version mismatch. Rebuild both from `~/xdna-driver`.

### ROCm toolbox containers
All ROCm containers use `HSA_OVERRIDE_GFX_VERSION=11.5.1` internally. If you need to run ROCm commands outside a toolbox, set this env var first.
