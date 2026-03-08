#!/bin/bash
# Strix Halo Local AI Setup
# Configures Lemonade Server with Vulkan backend + kyuz0 optimized binaries
# For AMD Strix Halo APU with Radeon 8060S iGPU (RDNA 3.5)
#
# Prerequisites:
#   - Fedora with Vulkan drivers (RADV)
#   - VGM BIOS set to 96GB GPU VRAM
#   - Secondary drive mounted at /mnt/Esuna (optional, for model storage)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Strix Halo Local AI Setup ==="
echo ""

# --- Step 1: Install Lemonade Server snap ---
echo "[1/7] Installing Lemonade Server..."
if snap list lemonade-server &>/dev/null; then
    echo "  Already installed: $(snap list lemonade-server | tail -1 | awk '{print $1, $2}')"
else
    sudo snap install lemonade-server
fi

# Disable the snap daemon (it defaults to ROCm which is slow on iGPU)
echo "[2/7] Disabling snap daemon (we start manually with Vulkan)..."
sudo snap stop --disable lemonade-server 2>/dev/null || true

# --- Step 2: Install kyuz0 Vulkan binaries ---
echo "[3/7] Setting up kyuz0 optimized Vulkan binaries..."
VULKAN_DIR="$HOME/.lemonade/bin/llamacpp/vulkan"
mkdir -p "$VULKAN_DIR"
cp "$SCRIPT_DIR/bin/llama-server-wrapper.sh" "$VULKAN_DIR/"
chmod +x "$VULKAN_DIR/llama-server-wrapper.sh"

if [ ! -f "$VULKAN_DIR/llama-server" ]; then
    echo ""
    echo "  NOTE: You need to copy kyuz0's Vulkan llama-server binary and libs to:"
    echo "    $VULKAN_DIR/"
    echo ""
    echo "  Required files:"
    echo "    llama-server, libggml-base.so.0, libggml-cpu.so.0, libggml-vulkan.so.0,"
    echo "    libggml.so.0, libllama.so.0, libggml-rpc.so.0, libmtmd.so.0"
    echo ""
    echo "  Get them from: https://github.com/kyuz0/amd-strix-halo-toolboxes"
    echo "  Or extract from the toolbox container:"
    echo "    toolbox enter strix-halo-vulkan"
    echo "    cp /usr/local/bin/llama-server $VULKAN_DIR/"
    echo "    cp /usr/local/lib/lib{ggml,llama,mtmd}*.so* $VULKAN_DIR/"
    echo ""
fi

# --- Step 3: Set environment variables ---
echo "[4/7] Configuring environment variables..."
if grep -q 'LEMONADE_LLAMACPP' ~/.bashrc; then
    echo "  Already configured in ~/.bashrc"
else
    cat >> ~/.bashrc << 'BASHRC'

# Lemonade - use kyuz0 Vulkan backend
export LEMONADE_LLAMACPP=vulkan
export LEMONADE_LLAMACPP_VULKAN_BIN="$HOME/.lemonade/bin/llamacpp/vulkan/llama-server-wrapper.sh"
BASHRC
    echo "  Added to ~/.bashrc"
fi

# Export for current session
export LEMONADE_LLAMACPP=vulkan
export LEMONADE_LLAMACPP_VULKAN_BIN="$HOME/.lemonade/bin/llamacpp/vulkan/llama-server-wrapper.sh"

# --- Step 4: Model storage on secondary drive ---
echo "[5/7] Setting up model storage..."
if [ -d /mnt/Esuna ]; then
    # Lemonade cache
    SNAP_CACHE="$HOME/snap/lemonade-server/current/.cache/huggingface/hub"
    ESUNA_HF="/mnt/Esuna/lemonade-cache/huggingface/hub"
    if [ -L "$SNAP_CACHE" ]; then
        echo "  Lemonade cache already symlinked to Esuna"
    elif [ -d /mnt/Esuna/lemonade-cache ]; then
        mkdir -p "$(dirname "$SNAP_CACHE")"
        rm -rf "$SNAP_CACHE"
        ln -s "$ESUNA_HF" "$SNAP_CACHE"
        echo "  Symlinked lemonade cache → Esuna"
    fi

    # ~/models
    if [ -L "$HOME/models" ]; then
        echo "  ~/models already symlinked to Esuna"
    elif [ -d /mnt/Esuna/models ]; then
        echo "  NOTE: Move ~/models to /mnt/Esuna/models manually if needed"
    fi
else
    echo "  /mnt/Esuna not found, using default storage"
fi

# Grant snap access to removable media
sudo snap connect lemonade-server:removable-media 2>/dev/null || true

# --- Step 5: Install VS Code extensions ---
echo "[6/7] VS Code extensions..."
if command -v code-insiders &>/dev/null; then
    # Install Continue
    code-insiders --install-extension Continue.continue 2>/dev/null && echo "  Installed: Continue" || echo "  Continue: already installed or unavailable"

    # Install Lemonade SDK
    code-insiders --install-extension lemonade-sdk.lemonade-sdk 2>/dev/null && echo "  Installed: Lemonade SDK" || echo "  Lemonade SDK: already installed or unavailable"

    # Copy Continue config
    mkdir -p "$HOME/.continue"
    if [ ! -f "$HOME/.continue/config.yaml" ]; then
        cp "$SCRIPT_DIR/vscode/continue-config.yaml" "$HOME/.continue/config.yaml"
        echo "  Continue config installed"
    else
        echo "  Continue config already exists (not overwriting)"
    fi
else
    echo "  VS Code Insiders not found, skipping extension install"
fi

# --- Step 6: Apply Lemonade extension patches ---
echo "[7/7] Applying Lemonade extension patches..."
bash "$SCRIPT_DIR/patches/apply-lemonade-patches.sh" 2>/dev/null || echo "  Patches skipped (extension not found)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To start the server:"
echo "  snap run lemonade-server serve --ctx-size 131072"
echo ""
echo "The router runs on port 8000, llama-server on port 8001."
echo "In VS Code Copilot Chat, select 'Lemonade' as the model provider."
echo "Set Lemonade Provider URL to: http://localhost:8000/api/v1"
echo ""
echo "Available models (download via Lemonade):"
echo "  - Qwen3-30B-A3B    (fast MoE, 3B active, ~57 tok/s)"
echo "  - Qwen3.5-122B-A10B (SOTA MoE, 10B active, ~8 tok/s)"
echo "  - Qwen3-VL-8B      (vision model)"
