# Strix Halo Local AI Setup

Local LLM/VLM + image generation for AMD Strix Halo APU (Radeon 8060S iGPU, RDNA 3.5) with 96GB unified VRAM.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  llama-server (kyuz0 Vulkan)          port 8001              │
│  └─ Qwen3.5-122B-A10B (~19 tok/s)    OpenAI-compatible API  │
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
| `llama-server` | 8001 | auto | LLM inference (kyuz0 Vulkan binary) |
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

The fix: run [kyuz0's Vulkan llama-server](https://github.com/kyuz0/amd-strix-halo-toolboxes) as a standalone systemd service with its own matching libs. Same OpenAI-compatible API, no snap dependency at runtime.

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
| Qwen3.5-122B-A10B | MoE | 10B | ~19 tok/s gen, ~45 tok/s prompt | Default, SOTA quality |
| Qwen3-30B-A3B | MoE | 3B | ~57 tok/s | Fast chat, coding |
| Qwen3-VL-8B | Dense | 8B | ~20 tok/s | Vision/multimodal |

To switch models, update the `-m` path in `llama-server.service` and restart:
```bash
systemctl --user restart llama-server
```

### Image Generation (ComfyUI on port 7860)
| Model | Size | Speed | Notes |
|-------|------|-------|-------|
| Flux-2-Klein-4B | ~15GB | ~10s/image | Best quality (Flux 2) |
| SDXL-Turbo | ~7GB | Fast | Good quality |
| SD-Turbo | ~2GB | Fastest | Decent quality |

## Why Vulkan?

ROCm doesn't detect Strix Halo's iGPU (GFX1151/RDNA 3.5), causing both LLM and image gen to fall back to CPU. Vulkan via RADV works perfectly and uses the full 96GB unified VRAM.

| | ROCm (CPU fallback) | Vulkan (GPU) |
|---|---|---|
| LLM speed | ~5 tok/s | **~19-57 tok/s** |
| Image gen | ~14 it/s (CPU) | **~198 it/s (VRAM)** |
| Image load | 57s | **4s** |

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
- Model path changed (snapshot hash) — update `-m` in service file
- kyuz0 binary missing — run `setup.sh` or copy binaries manually
- Esuna not mounted — check `mount | grep Esuna`

### Lemonade shows "llama-server failed to start"
This is expected if using the lemonade router for LLM. Use the standalone llama-server on port 8001 instead. Lemonade is only needed for the web UI and sd-cpp image gen.

### Port 8000 already in use
The snap daemon auto-restarts. Disable it:
```bash
sudo snap stop --disable lemonade-server
```
