# Changelog

## Build history

| Component | Version | Date | Notes |
|-----------|---------|------|-------|
| Model fleets | everyday (27B + llm-jp + ComfyUI) / text (Flash-Next) | 2026-10-01 | Models swapped as a saved set with health checks and smoke tests, replacing per-model flips (`strix-llm-switch.sh` retired) |
| halogen-flash-server | 0.17.1 | 2026-10-08 | Text-fleet engine for Qwen3.8-Flash-Next; first cut over from EngramHalo 2026-09-18 (0.11.6) |
| Mesa (Vulkan RADV) | 26.2.3 (Fedora 44) | 2026-09-29 | Routine update |
| Qwen3.8-27B on :8001 | julianmb ROCmFP4-FAST + mmproj-F16, ROCmFPX `75e67a92b` (q38rocm v1.7.0), MTP n=4 | 2026-09-28 | Everyday driver. Decode median 36.8 vs 25.7 tok/s on upstream Vulkan UD-Q4_K_XL (+43%), same box same evening. See README benchmarks |
| Kernel | 7.3.0-rc2 vanilla | 2026-09-09 | Running kernel |
| Mesa (Vulkan RADV) | 26.1.8 (Fedora 44) | 2026-09-07 | F43→44 upgrade. ⚠ MTP **decode** regression on gfx1151 (batched mat-vec split) — fix: `GGML_VK_MMV_NO_SPLIT=1` restores decode 15→23 t/s, prefill unaffected. See `docs/benchmarks-history.md` |
| llama.cpp | upstream master (Vulkan) | 2026-09-06 | Adopted plain upstream over the 69bf643 build for +15-27% prefill (upstream Vulkan `mul_mat_id` pad-K); fork/cherry-pick rejected (re-add decode loss) |
| Qwen3.8-27B VL on :8022 | unsloth UD-Q4_K_XL + mmproj-F16 | 2026-08-14 | Native VL + native MTP in one model; replaced Muse-Glimmer as the second resident |
| Kernel + boot params | 7.2.0-rc3 vanilla; `amd_iommu=off`, TTM cap 108GiB | 2026-08-09 | IOMMU off (5-12% on this platform); TTM capped below GTT so the GPU can't starve the host |
| Muse-Glimmer-30B on :8022 | custom ROCm-FP4 build | 2026-08-08 | Second resident (vision), ~26.5 t/s; retired 08-14, unit kept as rollback |
| llama.cpp | fresh upstream `~/llama.cpp` @ 69bf643 (Vulkan) | 2026-08-08 | Current build for :8001 and :8022 |
| llama.cpp | fresh upstream `~/llama.cpp` @ fb30ba9 (Vulkan) | 2026-07-10 | Native MTP (`--spec-type draft-mtp`), Qwen3.6 primary, ~75–86 t/s tg |
| Qwen3.6-35B-A3B MTP model | unsloth UD-Q4_K_XL (~22.85 GB) | 2026-07-10 | MTP layers grafted into GGUF; 256k ctx |
| llama.cpp | 8793 (Vulkan build from turboquant fork) | 2026-04-03 | 393 t/s pp, 22 t/s tg |
| llama-server | b8461 (kyuz0 Vulkan RADV) | 2026-03 | 351 t/s pp, 19 t/s tg (replaced) |
| llama-server | b8299 (official release) | 2026-03-13 | +40% prompt speed over b8119 |
| llama-server | b8119 (kyuz0 custom) | 2026-02 | Initial build |
| Kernel | 7.1.0-rc4 (vanilla) | 2026-04-04 | +12-37% pp over 6.19.9 |
| Kernel | 6.19.9 (Fedora 43) | 2026-03 | Previous stable |
| XRT | 2.23.0 | 2026-03-22 | Built from amd/xdna-driver submodule |
| amdxdna driver | 2.23.0 (DKMS) | 2026-03-22 | Out-of-tree, replaces kernel v0.6.0 |
| NPU firmware | 1.0.0.166 | 2026-03 | Protocol v6.x |

