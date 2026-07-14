#!/bin/bash
# lyra-stack-watchdog.sh — monitor the load-bearing systemd user services
# for the lyra + neo-gateway + local-LLM stack. If a service is inactive,
# try one restart; if the restart fails, ping Telegram (with per-service
# cooldown so a flapping unit doesn't spam the chat).
#
# Distinct from agent-mesh-watchdog (heartbeat staleness) and
# openclaw-watchdog (openclaw file watcher) — this one watches systemctl
# is-active on the actual stack units.

set -u
LOG_DIR="$HOME/.lyra-stack-watchdog"
LOG="$LOG_DIR/watchdog.log"
COOLDOWN_DIR="$LOG_DIR/cooldowns"
mkdir -p "$COOLDOWN_DIR"

CHAT_ID="8430134025"  # Zach's DM
COOLDOWN_MIN=30

# Which systemd unit serves the :8001 local LLM — follows the switch file written
# by ~/bin/strix-llm-switch.sh so this watchdog never fights a Gemma<->Qwen swap.
STRIX_LLM_UNIT="$(cat "$HOME/.config/strix-llm-unit" 2>/dev/null || echo llama-server)"
# ^ default is the Qwen 35B-A3B unit (llama-server), NOT gemma. A stale/unreadable marker
# used to make this watchdog spuriously START gemma and grab :8001 from the intended unit
# (caused repeated Gemma-revival churn 2026-07-15). Safe default = the long-standing driver.

# Critical services the stack depends on. Each must be a user-scope unit.
SERVICES=(
    lyra-backend.service
    neo-gateway.service
    neo-cloudflared.service
    "${STRIX_LLM_UNIT}.service"
    # llama-vlm-bom.service — REMOVED 2026-06-11: vlm-window stops it nightly after
    # its weekday window; restarting it here caused a stop/restart fight (32B GPU
    # load every ~10min all night) implicated in the 2026-06-11 kernel panics.
    # vlm-window + cf-strix-watchdog own this service's lifecycle.
    lyra-tg-bot.service
    comfyui.service
    openclaw-gateway.service
    openclaw-node.service
    hermes-gateway.service
    goose-gateway.service
    lyra-skill-server.service
)

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

token=$(grep -E '^RHERTON_BOT_TOKEN=' "$HOME/.openclaw/.env" 2>/dev/null | cut -d= -f2-)

alert() {
    local svc="$1"
    local detail="$2"
    local cooldown_file="$COOLDOWN_DIR/${svc}.last"
    local now=$(date +%s)

    if [ -f "$cooldown_file" ]; then
        local last=$(cat "$cooldown_file" 2>/dev/null || echo 0)
        local since=$(( (now - last) / 60 ))
        if [ "$since" -lt "$COOLDOWN_MIN" ]; then
            log "$svc: alert suppressed (cooldown ${since}/${COOLDOWN_MIN}m): $detail"
            return
        fi
    fi

    if [ -z "$token" ]; then
        log "$svc: NO token — cannot alert: $detail"
        return
    fi

    local text="lyra-stack-watchdog: $svc — $detail. check: journalctl --user -u $svc -n 50 --no-pager"
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --max-time 10 \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg c "$CHAT_ID" --arg t "$text" '{chat_id:$c, text:$t}')" \
        -o /dev/null && echo "$now" > "$cooldown_file"
    log "$svc: ALERTED: $detail"
}

for svc in "${SERVICES[@]}"; do
    state=$(systemctl --user is-active "$svc" 2>/dev/null || echo "unknown")
    if [ "$state" = "active" ]; then
        continue
    fi

    log "$svc: state=$state, attempting restart"
    if systemctl --user restart "$svc" 2>>"$LOG"; then
        sleep 3
        recheck=$(systemctl --user is-active "$svc" 2>/dev/null || echo "unknown")
        if [ "$recheck" = "active" ]; then
            log "$svc: restart OK (was $state)"
            # Don't alert on the recovery — Zach doesn't need to see it.
        else
            alert "$svc" "restart-attempted but still $recheck"
        fi
    else
        alert "$svc" "restart failed (was $state)"
    fi
done

# Compact log if it gets large (>10 MB)
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 10485760 ]; then
    tail -n 5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
