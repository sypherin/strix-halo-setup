#!/bin/bash
# Wrapper for Vulkan sd-server binary (stable-diffusion.cpp)
# Sets LD_LIBRARY_PATH so libstable-diffusion.so is found
DIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"
exec "$DIR/sd-server" "$@"
