#!/bin/bash
# Apply patches to Lemonade SDK extension for Qwen3 reasoning_content support
# Re-run this after any lemonade-sdk extension update

set -e

EXT_DIR="$HOME/.vscode-insiders/extensions/lemonade-sdk.lemonade-sdk-0.0.7"
PROVIDER="$EXT_DIR/out/provider.js"

if [ ! -f "$PROVIDER" ]; then
    # Try to find any version
    EXT_DIR=$(ls -d "$HOME/.vscode-insiders/extensions/lemonade-sdk.lemonade-sdk-"* 2>/dev/null | tail -1)
    if [ -z "$EXT_DIR" ]; then
        echo "ERROR: Lemonade SDK extension not found"
        exit 1
    fi
    PROVIDER="$EXT_DIR/out/provider.js"
    echo "Found extension at: $EXT_DIR"
fi

echo "Patching: $PROVIDER"
cp "$PROVIDER" "$PROVIDER.bak"

# Patch 1: Add reasoning_content support
if grep -q 'deltaObj?.reasoning_content' "$PROVIDER"; then
    echo "Patch 1 (reasoning_content): Already applied"
else
    sed -i 's/const maybeThinking = choice?.thinking ?? deltaObj?.thinking;/const maybeThinking = choice?.thinking ?? deltaObj?.thinking ?? deltaObj?.reasoning_content;/' "$PROVIDER"
    echo "Patch 1 (reasoning_content): Applied"
fi

# Patch 2: ThinkingPart fallback — emit as text when ThinkingPart API unavailable
if grep -q 'Fallback: emit thinking as regular text' "$PROVIDER"; then
    echo "Patch 2 (thinking fallback): Already applied"
else
    sed -i '/if (ThinkingCtor) {/{
        N
        s/progress\.report(new ThinkingCtor(text, id, metadata));/progress.report(new ThinkingCtor(text, id, metadata));\n                    } else {\n                        \/\/ Fallback: emit thinking as regular text so Copilot doesnt timeout\n                        progress.report(new vscode.LanguageModelTextPart(text));/
    }' "$PROVIDER"
    echo "Patch 2 (thinking fallback): Applied"
fi

# Patch 3: Disable thinking mode in request body
if grep -q 'chat_template_kwargs' "$PROVIDER"; then
    echo "Patch 3 (disable thinking): Already applied"
else
    sed -i 's/temperature: options.modelOptions?.temperature ?? 0.7,$/temperature: options.modelOptions?.temperature ?? 0.7,\n                chat_template_kwargs: { enable_thinking: false },/' "$PROVIDER"
    echo "Patch 3 (disable thinking): Applied"
fi

echo "Done. Backup saved to $PROVIDER.bak"
echo "Restart VS Code Insiders to apply changes."
