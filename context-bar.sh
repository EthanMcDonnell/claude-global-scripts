COLOR="blue"

C_RESET='\033[0m'
C_GRAY='\033[38;5;245m'
case "$COLOR" in
    orange)   C_ACCENT='\033[38;5;173m' ;;
    blue)     C_ACCENT='\033[38;5;74m' ;;
    teal)     C_ACCENT='\033[38;5;66m' ;;
    green)    C_ACCENT='\033[38;5;71m' ;;
    lavender) C_ACCENT='\033[38;5;139m' ;;
    rose)     C_ACCENT='\033[38;5;132m' ;;
    gold)     C_ACCENT='\033[38;5;136m' ;;
    slate)    C_ACCENT='\033[38;5;60m' ;;
    cyan)     C_ACCENT='\033[38;5;37m' ;;
    *)        C_ACCENT="$C_GRAY" ;;
esac

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // .model.id // "?"')
MODEL_ID=$(echo "$input" | jq -r '.model.id')
cwd=$(echo "$input" | jq -r '.cwd // empty')
dir=$(basename "$cwd" 2>/dev/null || echo "?")

CONTEXT_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
USAGE=$(echo "$input" | jq '.context_window.current_usage')
max_k=$((CONTEXT_SIZE / 1000))

# Determine max output tokens (capped at 20000 for autocompact threshold calculation)
MAX_OUTPUT_CAP=20000
case "$MODEL_ID" in
    *opus-4-6*)              MODEL_MAX=128000 ;;
    *opus-4-5*|*sonnet-4*|*haiku-4*) MODEL_MAX=64000 ;;
    *opus-4*)                MODEL_MAX=32000 ;;
    *3-5*)                   MODEL_MAX=8192 ;;
    *claude-3-opus*)         MODEL_MAX=4096 ;;
    *claude-3-sonnet*)       MODEL_MAX=8192 ;;
    *claude-3-haiku*)        MODEL_MAX=4096 ;;
    *)                       MODEL_MAX=32000 ;;
esac
[ "$MODEL_MAX" -lt "$MAX_OUTPUT_CAP" ] && MAX_OUTPUT=$MODEL_MAX || MAX_OUTPUT=$MAX_OUTPUT_CAP

# Effective headroom available = context size minus max output reservation
EHA=$((CONTEXT_SIZE - MAX_OUTPUT))

# Autocompact threshold
if [ -n "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" ]; then
    PCT_THRESHOLD=$((EHA * CLAUDE_AUTOCOMPACT_PCT_OVERRIDE / 100))
    DEFAULT_THRESHOLD=$((EHA - 13000))
    [ "$PCT_THRESHOLD" -lt "$DEFAULT_THRESHOLD" ] && THRESHOLD=$PCT_THRESHOLD || THRESHOLD=$DEFAULT_THRESHOLD
else
    THRESHOLD=$((EHA - 13000))
fi

# Check if autocompact is enabled
AUTOCOMPACT_ENABLED=1
[ -n "$DISABLE_COMPACT" ] && [ "$DISABLE_COMPACT" != "0" ] && [ "$DISABLE_COMPACT" != "false" ] && AUTOCOMPACT_ENABLED=0
[ -n "$DISABLE_AUTO_COMPACT" ] && [ "$DISABLE_AUTO_COMPACT" != "0" ] && [ "$DISABLE_AUTO_COMPACT" != "false" ] && AUTOCOMPACT_ENABLED=0
CONFIG_FILE="$HOME/.claude.json"
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_VAL=$(jq -r 'if has("autoCompactEnabled") then .autoCompactEnabled else true end' "$CONFIG_FILE" 2>/dev/null)
    [ "$CONFIG_VAL" = "false" ] && AUTOCOMPACT_ENABLED=0
fi

# Effective denominator: threshold when autocompact on, full EHA otherwise
[ "$AUTOCOMPACT_ENABLED" = "1" ] && EFFECTIVE=$THRESHOLD || EFFECTIVE=$EHA

if [ "$USAGE" != "null" ]; then
    CURRENT_TOKENS=$(echo "$USAGE" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    pct=$((CURRENT_TOKENS * 100 / EFFECTIVE))
    [ "$pct" -gt 100 ] && pct=100
    pct_prefix=""
else
    pct=$((20000 * 100 / EFFECTIVE))
    pct_prefix="~"
fi

ctx="${C_GRAY}💬 ${C_ACCENT}${pct_prefix}${pct}%${C_GRAY} of ${max_k}k tokens"

# Fetch 5-hour plan usage (cached for 60s)
CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_TTL=60
usage_segment=""

fetch_usage=0
if [[ -f "$CACHE_FILE" ]]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
    [[ $cache_age -gt $CACHE_TTL ]] && fetch_usage=1
else
    fetch_usage=1
fi

if [[ $fetch_usage -eq 1 ]]; then
    token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [[ -z "$token" && -f "$HOME/.claude/.credentials.json" ]]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    fi
    if [[ -n "$token" ]]; then
        curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -o "$CACHE_FILE" 2>/dev/null || rm -f "$CACHE_FILE"
    fi
fi

if [[ -f "$CACHE_FILE" ]]; then
    utilization=$(jq -r '.five_hour.utilization // empty' "$CACHE_FILE" 2>/dev/null)
    resets_at=$(jq -r '.five_hour.resets_at // empty' "$CACHE_FILE" 2>/dev/null)

    if [[ -n "$utilization" && -n "$resets_at" ]]; then
        now=$(date +%s)
        reset_epoch=$(python3 -c \
            "from datetime import datetime; print(int(datetime.fromisoformat('${resets_at}'.replace('Z','+00:00')).timestamp()))" \
            2>/dev/null)
        if [[ -n "$reset_epoch" ]]; then
            diff=$(( reset_epoch - now ))
            if [[ $diff -le 0 ]]; then
                reset_str="resetting"
            elif [[ $diff -lt 3600 ]]; then
                reset_str="$(( diff / 60 ))m"
            else
                reset_str="$(( diff / 3600 ))h $(( (diff % 3600) / 60 ))m"
            fi
            usage_segment="${C_GRAY}⚡ ${C_ACCENT}${utilization}%${C_GRAY} 5hr (${reset_str})"
        else
            usage_segment="${C_GRAY}⚡ ${C_ACCENT}${utilization}%${C_GRAY} 5hr"
        fi
    fi
fi

output="${C_ACCENT}${model}${C_RESET}
${C_GRAY}📁 ${dir}${C_RESET}"
[ -n "$usage_segment" ] && output="${output}
${usage_segment}${C_RESET}"
output="${output}
${C_GRAY}${ctx}${C_RESET}"
printf '%b\n' "$output"
