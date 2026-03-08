# Strix Halo Local AI Setup

Local LLM/VLM + image generation setup for AMD Strix Halo APU (Radeon 8060S iGPU, RDNA 3.5) with 96GB unified VRAM.

## What this does

- Configures [Lemonade Server](https://github.com/lemonade-sdk/lemonade) with **Vulkan backend** (~2x faster than ROCm on iGPU)
- Integrates [kyuz0's optimized llama-server](https://github.com/kyuz0/amd-strix-halo-toolboxes) binary for LLM inference
- Swaps ROCm sd-cpp with [Vulkan sd-cpp](https://github.com/leejet/stable-diffusion.cpp) for GPU-accelerated image generation
- Patches Lemonade VS Code extension for Qwen3 `reasoning_content` streaming
- Sets up VS Code Continue extension for local model access
- Configures model storage on secondary drive to save space

## Quick start

```bash
git clone git@github.com:sypherin/strix-halo-setup.git
cd strix-halo-setup
chmod +x setup.sh bin/*.sh patches/*.sh
./setup.sh
```

## Starting the server

```bash
snap run lemonade-server serve --ctx-size 131072 --max-loaded-models 2
```

- Web UI (chat + image gen): http://localhost:8000
- LLM API: port 8001
- Image gen API: port 8002

## Structure

```
├── setup.sh                              # Main setup script
├── bin/
│   ├── llama-server-wrapper.sh           # LD_LIBRARY_PATH wrapper for kyuz0 LLM binary
│   └── sd-server-wrapper.sh              # LD_LIBRARY_PATH wrapper for Vulkan sd-cpp binary
├── patches/
│   ├── lemonade-provider-reasoning.patch # Patch descriptions (human-readable)
│   └── apply-lemonade-patches.sh         # Auto-apply patches to extension
└── vscode/
    └── continue-config.yaml              # Continue extension config
```

## Models

### LLM
| Model | Type | Active Params | Speed | Use case |
|-------|------|---------------|-------|----------|
| Qwen3-30B-A3B | MoE | 3B | ~57 tok/s | Fast chat, coding |
| Qwen3.5-122B-A10B | MoE | 10B | ~8 tok/s | SOTA quality |
| Qwen3-VL-8B | Dense | 8B | ~20 tok/s | Vision/multimodal |

### Image Generation
| Model | Size | Speed | Notes |
|-------|------|-------|-------|
| Flux-2-Klein-4B | ~15GB | ~10s/image | Best quality (Flux 2) |
| SDXL-Turbo | ~7GB | Fast | Good quality |
| SD-Turbo | ~2GB | Fastest | Decent quality |

## Why Vulkan?

ROCm doesn't detect Strix Halo's iGPU (GFX1151/RDNA 3.5), causing both LLM and image gen to fall back to CPU. Vulkan via RADV works perfectly and uses the full 96GB unified VRAM.

| | ROCm (CPU fallback) | Vulkan (GPU) |
|---|---|---|
| LLM speed | ~5 tok/s | **~57 tok/s** |
| Image gen | ~14 it/s (CPU) | **~198 it/s (VRAM)** |
| Image load | 57s | **4s** |

## Notes

- Vulkan uses RADV driver (Mesa). Ensure `vulkaninfo` works before setup.
- The snap daemon is disabled — start manually with `snap run lemonade-server serve`.
- Lemonade extension patches are overwritten on extension updates — re-run `patches/apply-lemonade-patches.sh`.
- sd-cpp Vulkan swap is overwritten if `sd-cpp:rocm` recipe is reinstalled — re-run `setup.sh`.
- BIOS VGM should be set to 96GB for maximum model capacity.
