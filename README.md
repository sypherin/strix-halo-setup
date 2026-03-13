# Strix Halo Local AI Setup

Local LLM/VLM + image generation for AMD Strix Halo APU (Radeon 8060S iGPU, RDNA 3.5) with 96GB unified VRAM.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  llama-server (Vulkan, b8299)         port 8001              │
│  └─ Qwen3.5-122B-A10B (~20 tok/s)    OpenAI-compatible API  │
│                                                              │
│  ComfyUI (toolbox)                    port 7860              │
│  └─ Image/video generation            Vulkan backend         │
│                                                              │
│  Lemonade router (optional)           port 8000              │
│  └─ Web UI + sd-cpp image gen         Vulkan backend         │
└──────────────────────────────────────────────────────────────┘
```

All services run as **systemd user services** with auto-start on boot.

## Quick start

```bash
git clone https://github.com/sypherin/strix-halo-setup.git
cd strix-halo-setup
chmod +x setup.sh bin/*.sh patches/*.sh
./setup.sh
systemctl --user start llama-server comfyui
```

## Services

| Service | Port | Startup | Description |
|---------|------|---------|-------------|
| `llama-server` | 8001 | auto | LLM inference (llama.cpp b8299, Vulkan) |
| `comfyui` | 7860 | auto | Image/video gen (toolbox container) |
| `lemonade` | 8000 | manual | Web UI + sd-cpp (optional, see below) |

### Managing services

```bash
# Status
systemctl --user status llama-server comfyui

# Start/stop
systemctl --user start llama-server
systemctl --user stop llama-server

# Logs
journalctl --user -u llama-server -f

# Health check
curl http://localhost:8001/health
```

## Why standalone llama-server instead of Lemonade?

The Lemonade snap has two bugs as of v9.4.1 (snap rev 104):

1. **ABI breakage**: The bundled Vulkan `libllama.so` references `ggml_build_forward_select` which doesn't exist in the bundled `libggml-base.so`. This causes `exit code 127` (symbol lookup error). Snap auto-updates keep breaking this.
2. **Startup timeout**: The router has a ~15s timeout for llama-server startup. Loading a 72GB model from a secondary drive takes ~90s. The router kills llama-server before it finishes loading.

The fix: run the [official llama.cpp Vulkan build](https://github.com/ggml-org/llama.cpp/releases) as a standalone systemd service. The official release includes pre-built Vulkan Linux binaries that work on Strix Halo out of the box (no custom patches needed — kyuz0's Vulkan builds are essentially stock llama.cpp). Same OpenAI-compatible API, no snap dependency at runtime.

## Critical configuration notes

### --mmap is REQUIRED (do NOT use --no-mmap)

Strix Halo has 96GB unified memory shared between CPU and GPU, but Linux only sees ~30GB as system RAM. Using `--no-mmap` forces the entire model (72GB for Qwen3.5-122B) into system RAM, causing:
- All 30GB RAM consumed + 6.7GB swap thrashing
- System becomes unusable (massive lag)

With `--mmap`, the Vulkan driver maps model weights directly into unified VRAM. System RAM stays at ~6GB used.

### Model path contains a snapshot hash

The model path in `llama-server.service` includes a HuggingFace snapshot hash:
```
models--unsloth--Qwen3.5-122B-A10B-GGUF/snapshots/51eab4d59d53f573fb9206cb3ce613f1d0aa392b/...
```
If you re-download the model, the hash changes. Update the path in the service file.

### Snap daemon conflicts on port 8000

The lemonade-server snap runs a built-in daemon on port 8000 (ROCm mode). It must be disabled before starting the lemonade systemd service:
```bash
sudo snap stop --disable lemonade-server
```

### Snap auto-updates break Vulkan binaries

When the lemonade-server snap updates, it overwrites the Vulkan directory at `~/snap/lemonade-server/<rev>/.cache/lemonade/bin/llamacpp/vulkan/`. This does NOT affect the standalone llama-server service (which uses `~/.lemonade/bin/`), but will break lemonade router's LLM loading. Re-run `setup.sh` after snap updates.

## Structure

```
├── setup.sh                              # Main setup script
├── systemd/
│   ├── llama-server.service              # Standalone LLM server (always enabled)
│   ├── comfyui.service                   # ComfyUI in toolbox (auto-enabled if toolbox exists)
│   └── lemonade.service                  # Lemonade router (optional, disabled by default)
├── bin/
│   ├── llama-server-wrapper.sh           # LD_LIBRARY_PATH wrapper for kyuz0 LLM binary
│   └── sd-server-wrapper.sh              # LD_LIBRARY_PATH wrapper for Vulkan sd-cpp binary
├── patches/
│   ├── lemonade-provider-reasoning.patch # Patch descriptions (human-readable)
│   └── apply-lemonade-patches.sh         # Auto-apply patches to VS Code extension
└── vscode/
    └── continue-config.yaml              # Continue extension config
```

## Models

### LLM (llama-server on port 8001)
| Model | Type | Active Params | Speed | Use case |
|-------|------|---------------|-------|----------|
| Qwen3.5-122B-A10B | MoE | 10B | ~20 tok/s gen, ~63 tok/s prompt | Default, SOTA quality |
| Qwen3-30B-A3B | MoE | 3B | ~57 tok/s | Fast chat, coding |
| Qwen3-VL-8B | Dense | 8B | ~20 tok/s | Vision/multimodal |

To switch models, update the `-m` path in `llama-server.service` and restart:
```bash
systemctl --user restart llama-server
```

### Image/Video Generation (ComfyUI on port 7860)

Toolbox: `kyuz0/amd-strix-halo-comfyui:latest` (ROCm 7 nightlies)

| Workflow | Type | Notes |
|----------|------|-------|
| HunyuanVideo 1.5 | I2V / T2V | 4-step LoRA, 720p, configured for 32GB |
| Qwen Image 2512 | T2I | Use BF16 (not FP8 — FP8 is broken on gfx1151) |
| Qwen Image Edit | Image Editing | Lightning LoRA, 4/20 steps |
| Wan 2.2 | I2V / T2V | 14B model with 4-step Lightning LoRA |
| LTX-2 | Video+Audio | Audio OOMs on 128GB — reduce VRAM reservation |

Flags: `--bf16-vae --disable-mmap --cache-none` (all critical for gfx1151).

FP8 is a **software limitation** on Strix Halo — always use **BF16** models.

## Why Vulkan?

ROCm doesn't detect Strix Halo's iGPU (GFX1151/RDNA 3.5), causing both LLM and image gen to fall back to CPU. Vulkan via RADV works perfectly and uses the full 96GB unified VRAM.

| | ROCm (CPU fallback) | Vulkan (GPU) |
|---|---|---|
| LLM speed | ~5 tok/s | **~19-57 tok/s** |
| Image gen | ~14 it/s (CPU) | **~198 it/s (VRAM)** |
| Image load | 57s | **4s** |

## Upgrading llama-server

The llama-server binary at `~/.lemonade/bin/llamacpp/vulkan/` can be upgraded independently from lemonade. Official releases include pre-built Vulkan binaries.

```bash
# Download latest release (replace b8299 with current version)
cd /tmp
wget https://github.com/ggml-org/llama.cpp/releases/download/b8299/llama-b8299-bin-ubuntu-vulkan-x64.tar.gz
tar xzf llama-b8299-bin-ubuntu-vulkan-x64.tar.gz

# Stop service, replace binaries, restart
systemctl --user stop llama-server
VULKAN_DIR="$HOME/.lemonade/bin/llamacpp/vulkan"
SRC="/tmp/llama-b8299/llama-b8299"  # adjust path for extracted dir

# Backup old build
mkdir -p "$VULKAN_DIR/backup-$(date +%Y%m%d)"
cp "$VULKAN_DIR/llama-server" "$VULKAN_DIR"/lib*.so* "$VULKAN_DIR/backup-$(date +%Y%m%d)/"

# Copy new binaries (must include all .so files — b8299+ dynamically loads backends)
cp "$SRC/llama-server" "$VULKAN_DIR/"
cp "$SRC"/libggml-base.so.0 "$SRC"/libggml.so.0 "$SRC"/libllama.so.0 "$SRC"/libmtmd.so.0 "$VULKAN_DIR/"
cp "$SRC"/libggml-vulkan.so "$SRC"/libggml-rpc.so "$VULKAN_DIR/"
cp "$SRC"/libggml-cpu-*.so "$VULKAN_DIR/"
chmod +x "$VULKAN_DIR/llama-server"

systemctl --user start llama-server
curl http://localhost:8001/health  # wait for model to load (~35s)
```

### Build history
| Build | Date | Prompt tok/s | Gen tok/s | Notes |
|-------|------|-------------|-----------|-------|
| b8119 | 2026-02 | ~45 | ~19 | kyuz0 custom build (initial) |
| b8299 | 2026-03-13 | **~63** | **~20** | Official release, +40% prompt speed |

Key improvements in b8299: Vulkan Flash Attention refactor, AMD partial offloading perf fix, multiple data race fixes.

## Troubleshooting

### System is laggy when model is loaded
Check if `--no-mmap` is set (it shouldn't be):
```bash
systemctl --user cat llama-server | grep mmap
```
Must show `--mmap`, not `--no-mmap`. See [critical notes](#--mmap-is-required-do-not-use---no-mmap).

### llama-server fails to start
Check logs:
```bash
journalctl --user -u llama-server --no-pager -n 50
```
Common causes:
- **"no usable GPU found"** — Vulkan backend libs not found. Ensure `libggml-vulkan.so` (not just `.so.0`) exists in `~/.lemonade/bin/llamacpp/vulkan/`. b8299+ dynamically loads backends by filename without version suffix.
- **Model path changed** (snapshot hash) — update `-m` in service file
- **Binary missing** — download from [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)
- **Esuna not mounted** — check `mount | grep Esuna`

### Lemonade shows "llama-server failed to start"
This is expected if using the lemonade router for LLM. Use the standalone llama-server on port 8001 instead. Lemonade is only needed for the web UI and sd-cpp image gen.

### Port 8000 already in use
The snap daemon auto-restarts. Disable it:
```bash
sudo snap stop --disable lemonade-server
```
