#!/bin/bash
# Wrapper for kyuz0's optimized llama-server Vulkan binary
# Sets LD_LIBRARY_PATH so shared libs (libggml-vulkan.so, libllama.so, etc.) are found
DIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"
exec "$DIR/llama-server" "$@"
