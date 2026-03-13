#!/bin/bash
# Strix Halo Local AI Setup
# Configures local LLM + image generation for AMD Strix Halo APU (Radeon 8060S, RDNA 3.5)
#
# Architecture:
#   - llama-server (kyuz0 Vulkan) → port 8001 (OpenAI-compatible LLM API)
#   - Lemonade router             → port 8000 (web UI + sd-cpp image gen, optional)
#   - ComfyUI (toolbox)           → port 7860 (advanced image/video gen, optional)
#
# Prerequisites:
#   - Fedora with Vulkan drivers (RADV)
#   - VGM BIOS set to 96GB GPU VRAM
#   - User lingering enabled: loginctl enable-linger $USER
#   - Secondary drive mounted at /mnt/Esuna (optional, for model storage)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_DIR="$HOME/.config/systemd/user"

echo "=== Strix Halo Local AI Setup ==="
echo ""

# --- Step 1: Install Lemonade Server snap ---
echo "[1/9] Installing Lemonade Server..."
if snap list lemonade-server &>/dev/null; then
    echo "  Already installed: $(snap list lemonade-server | tail -1 | awk '{print $1, $2}')"
else
    sudo snap install lemonade-server
fi

# Disable the snap daemon (it defaults to ROCm, conflicts with our services)
echo "[2/9] Disabling snap daemon..."
sudo snap stop --disable lemonade-server 2>/dev/null || true

# --- Step 2: Install Vulkan llama-server binary ---
echo "[3/9] Setting up Vulkan llama-server..."
VULKAN_DIR="$HOME/.lemonade/bin/llamacpp/vulkan"
LLAMA_BUILD="b8299"  # Update this when upgrading
mkdir -p "$VULKAN_DIR"
cp "$SCRIPT_DIR/bin/llama-server-wrapper.sh" "$VULKAN_DIR/"
chmod +x "$VULKAN_DIR/llama-server-wrapper.sh"

if [ ! -f "$VULKAN_DIR/llama-server" ]; then
    echo "  Downloading official llama.cpp $LLAMA_BUILD Vulkan build..."
    LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/llama-${LLAMA_BUILD}-bin-ubuntu-vulkan-x64.tar.gz"
    curl -L -o /tmp/llama-vulkan.tar.gz "$LLAMA_URL" 2>/dev/null
    mkdir -p /tmp/llama-vulkan-extract
    tar xzf /tmp/llama-vulkan.tar.gz -C /tmp/llama-vulkan-extract
    LLAMA_SRC=$(find /tmp/llama-vulkan-extract -name "llama-server" -type f -printf '%h\n' | head -1)
    if [ -n "$LLAMA_SRC" ]; then
        cp "$LLAMA_SRC/llama-server" "$VULKAN_DIR/"
        cp "$LLAMA_SRC"/libggml-base.so.0 "$LLAMA_SRC"/libggml.so.0 "$VULKAN_DIR/"
        cp "$LLAMA_SRC"/libllama.so.0 "$LLAMA_SRC"/libmtmd.so.0 "$VULKAN_DIR/"
        cp "$LLAMA_SRC"/libggml-vulkan.so "$LLAMA_SRC"/libggml-rpc.so "$VULKAN_DIR/"
        cp "$LLAMA_SRC"/libggml-cpu-*.so "$VULKAN_DIR/"
        chmod +x "$VULKAN_DIR/llama-server"
        echo "  Installed llama.cpp $LLAMA_BUILD Vulkan"
    else
        echo "  ERROR: Failed to extract llama-server from archive"
    fi
    rm -rf /tmp/llama-vulkan.tar.gz /tmp/llama-vulkan-extract
else
    echo "  llama-server already present ($(ls -la "$VULKAN_DIR/llama-server" | awk '{print $5}') bytes)"
    echo "  To upgrade, delete $VULKAN_DIR/llama-server and re-run setup.sh"
fi

# Replace snap's bundled Vulkan llama-server with our working build (fixes ABI breakage)
# The snap's libllama.so is built against a different libggml-base.so version,
# causing "undefined symbol: ggml_build_forward_select" crashes. This persists
# across snap auto-updates, so we overwrite every time setup.sh runs.
SNAP_VK_DIR="$HOME/snap/lemonade-server/current/.cache/lemonade/bin/llamacpp/vulkan"
if [ -d "$SNAP_VK_DIR" ] && [ -f "$VULKAN_DIR/llama-server" ]; then
    echo "  Replacing snap's Vulkan binaries with kyuz0's..."
    for f in llama-server; do
        [ -f "$SNAP_VK_DIR/$f" ] && [ ! -f "$SNAP_VK_DIR/$f.snap.bak" ] && \
            cp "$SNAP_VK_DIR/$f" "$SNAP_VK_DIR/$f.snap.bak"
        cp "$VULKAN_DIR/$f" "$SNAP_VK_DIR/$f"
    done
    # Copy matching shared libs
    cp "$VULKAN_DIR/libllama.so.0"       "$SNAP_VK_DIR/libllama.so.0" 2>/dev/null || true
    cp "$VULKAN_DIR/libggml-base.so.0"   "$SNAP_VK_DIR/libggml-base.so.0" 2>/dev/null || true
    cp "$VULKAN_DIR/libggml.so.0"        "$SNAP_VK_DIR/libggml.so.0" 2>/dev/null || true
    cp "$VULKAN_DIR/libggml-vulkan.so.0" "$SNAP_VK_DIR/libggml-vulkan.so" 2>/dev/null || true
    cp "$VULKAN_DIR/libggml-cpu.so.0"    "$SNAP_VK_DIR/libggml-cpu.so.0" 2>/dev/null || true
    cp "$VULKAN_DIR/libggml-rpc.so.0"    "$SNAP_VK_DIR/libggml-rpc.so" 2>/dev/null || true
    cp "$VULKAN_DIR/libmtmd.so.0"        "$SNAP_VK_DIR/libmtmd.so.0" 2>/dev/null || true
    # Fix symlinks
    cd "$SNAP_VK_DIR"
    ln -sf libllama.so.0 libllama.so 2>/dev/null || true
    ln -sf libggml-base.so.0 libggml-base.so 2>/dev/null || true
    ln -sf libggml.so.0 libggml.so 2>/dev/null || true
    ln -sf libmtmd.so.0 libmtmd.so 2>/dev/null || true
    cd "$SCRIPT_DIR"
    echo "  Snap Vulkan binaries replaced with kyuz0's (lemonade router will use these)"
else
    echo "  Snap Vulkan dir not found (install llamacpp:vulkan recipe first)"
fi

# --- Step 3: Install Vulkan sd-cpp for image generation ---
echo "[4/9] Setting up Vulkan sd-cpp for image generation..."
snap run lemonade-server recipes --install sd-cpp:rocm 2>/dev/null || true

SDCPP_DIR="$HOME/snap/lemonade-server/current/.cache/lemonade/bin/sd-cpp/rocm/build/bin"
VULKAN_SD_DIR="$HOME/.lemonade/bin/sd-cpp/vulkan"
mkdir -p "$VULKAN_SD_DIR"
cp "$SCRIPT_DIR/bin/sd-server-wrapper.sh" "$VULKAN_SD_DIR/"
chmod +x "$VULKAN_SD_DIR/sd-server-wrapper.sh"

if [ -d "$SDCPP_DIR" ]; then
    if [ ! -f "$VULKAN_SD_DIR/sd-server" ]; then
        echo "  Downloading Vulkan sd-cpp binary..."
        SDCPP_URL="https://github.com/leejet/stable-diffusion.cpp/releases/latest/download/sd-master-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip"
        curl -L -o /tmp/sd-vulkan.zip "$SDCPP_URL" 2>/dev/null || {
            curl -L -o /tmp/sd-vulkan.zip "https://github.com/leejet/stable-diffusion.cpp/releases/download/master-523-c8fb3d2/sd-master-c8fb3d2-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip"
        }
        unzip -o /tmp/sd-vulkan.zip -d "$VULKAN_SD_DIR/"
        rm -f /tmp/sd-vulkan.zip
    fi

    if [ -f "$VULKAN_SD_DIR/sd-server" ]; then
        [ -f "$SDCPP_DIR/sd-server" ] && [ ! -f "$SDCPP_DIR/sd-server.rocm.bak" ] && \
            cp "$SDCPP_DIR/sd-server" "$SDCPP_DIR/sd-server.rocm.bak"
        [ -f "$SDCPP_DIR/libstable-diffusion.so" ] && [ ! -f "$SDCPP_DIR/libstable-diffusion.so.rocm.bak" ] && \
            cp "$SDCPP_DIR/libstable-diffusion.so" "$SDCPP_DIR/libstable-diffusion.so.rocm.bak"
        cp "$VULKAN_SD_DIR/sd-server" "$SDCPP_DIR/sd-server"
        cp "$VULKAN_SD_DIR/libstable-diffusion.so" "$SDCPP_DIR/libstable-diffusion.so"
        echo "  Swapped ROCm sd-server with Vulkan"
    fi
else
    echo "  sd-cpp not yet installed. Run: snap run lemonade-server recipes --install sd-cpp:rocm"
fi

# --- Step 4: Model storage on secondary drive ---
echo "[5/9] Setting up model storage..."
if [ -d /mnt/Esuna ]; then
    SNAP_CACHE="$HOME/snap/lemonade-server/current/.cache/huggingface/hub"
    ESUNA_HF="/mnt/Esuna/lemonade-cache/huggingface/hub"
    if [ -L "$SNAP_CACHE" ]; then
        echo "  Lemonade cache already symlinked to Esuna"
    elif [ -d /mnt/Esuna/lemonade-cache ]; then
        mkdir -p "$(dirname "$SNAP_CACHE")"
        rm -rf "$SNAP_CACHE"
        ln -s "$ESUNA_HF" "$SNAP_CACHE"
        echo "  Symlinked lemonade cache -> Esuna"
    fi
    sudo snap connect lemonade-server:removable-media 2>/dev/null || true
else
    echo "  /mnt/Esuna not found, using default storage"
fi

# --- Step 5: Install systemd services ---
echo "[6/9] Installing systemd services..."
mkdir -p "$SYSTEMD_DIR"

# llama-server (primary LLM service — always install)
cp "$SCRIPT_DIR/systemd/llama-server.service" "$SYSTEMD_DIR/"
echo "  Installed llama-server.service"

# ComfyUI (install if either toolbox exists)
if toolbox list 2>/dev/null | grep -q "strix-halo-comfyui\|strix-halo-image-video"; then
    cp "$SCRIPT_DIR/systemd/comfyui.service" "$SYSTEMD_DIR/"
    echo "  Installed comfyui.service"
else
    echo "  Skipped comfyui.service (no ComfyUI toolbox found)"
    echo "  Create one with: toolbox create strix-halo-comfyui --image docker.io/kyuz0/amd-strix-halo-comfyui:latest -- --device /dev/dri --device /dev/kfd --group-add video --group-add render --security-opt seccomp=unconfined"
fi

# Lemonade router (optional — for web UI and image gen)
cp "$SCRIPT_DIR/systemd/lemonade.service" "$SYSTEMD_DIR/"
echo "  Installed lemonade.service (disabled by default)"

# Enable user lingering so services start at boot without login
loginctl enable-linger "$USER" 2>/dev/null || true

# Reload and enable services
systemctl --user daemon-reload
systemctl --user enable llama-server.service
echo "  Enabled llama-server.service (auto-start on boot)"

if [ -f "$SYSTEMD_DIR/comfyui.service" ]; then
    systemctl --user enable comfyui.service
    echo "  Enabled comfyui.service (auto-start on boot)"
fi

# Lemonade is NOT enabled by default due to snap daemon conflict
echo "  lemonade.service NOT enabled (run: sudo snap stop --disable lemonade-server && systemctl --user enable --now lemonade.service)"

# --- Step 6: Set environment variables ---
echo "[7/9] Configuring environment variables..."
if grep -q 'LEMONADE_LLAMACPP' ~/.bashrc; then
    echo "  Already configured in ~/.bashrc"
else
    cat >> ~/.bashrc << 'BASHRC'

# Lemonade - use kyuz0 Vulkan backend
export LEMONADE_LLAMACPP=vulkan
BASHRC
    echo "  Added to ~/.bashrc"
fi

# --- Step 7: Install VS Code extensions ---
echo "[8/9] VS Code extensions..."
if command -v code-insiders &>/dev/null; then
    code-insiders --install-extension Continue.continue 2>/dev/null && echo "  Installed: Continue" || echo "  Continue: already installed or unavailable"
    code-insiders --install-extension lemonade-sdk.lemonade-sdk 2>/dev/null && echo "  Installed: Lemonade SDK" || echo "  Lemonade SDK: already installed or unavailable"

    mkdir -p "$HOME/.continue"
    if [ ! -f "$HOME/.continue/config.yaml" ]; then
        cp "$SCRIPT_DIR/vscode/continue-config.yaml" "$HOME/.continue/config.yaml"
        echo "  Continue config installed"
    else
        echo "  Continue config already exists (not overwriting)"
    fi
else
    echo "  VS Code Insiders not found, skipping"
fi

# --- Step 8: Apply Lemonade extension patches ---
echo "[9/9] Applying Lemonade extension patches..."
bash "$SCRIPT_DIR/patches/apply-lemonade-patches.sh" 2>/dev/null || echo "  Patches skipped (extension not found)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Services (auto-start on boot):"
echo "  llama-server  → http://localhost:8001/v1  (Qwen3.5-122B, OpenAI API)"
echo "  comfyui       → http://localhost:7860      (image/video generation)"
echo ""
echo "Optional (requires: sudo snap stop --disable lemonade-server):"
echo "  lemonade      → http://localhost:8000      (web UI + sd-cpp image gen)"
echo ""
echo "Start services now:"
echo "  systemctl --user start llama-server comfyui"
echo ""
echo "Check status:"
echo "  systemctl --user status llama-server comfyui"
echo "  curl http://localhost:8001/health"
echo ""
