#!/usr/bin/env bash

# Cache configuration
CACHE_DIR="${HOME}/.cache/claude/statusline"
CACHE_FILE="${CACHE_DIR}/usage.json"
LOCK_FILE="${CACHE_DIR}/usage.lock"
CACHE_MAX_AGE=180        # seconds
LOCK_MAX_AGE=30          # seconds
DEFAULT_RATE_LIMIT_BACKOFF=300
TOKEN_CACHE_FILE="${CACHE_DIR}/token.cache"
TOKEN_CACHE_MAX_AGE=3600 # 1 hour

# API configuration
USAGE_API_HOST="api.anthropic.com"
USAGE_API_PATH="/api/oauth/usage"
USAGE_API_TIMEOUT=5

# Ensure cache directory exists
ensure_cache_dir() {
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
}

# Get current timestamp
now() {
    date +%s
}

# Get file modification time
file_mtime() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f %m "$file" 2>/dev/null || echo 0
    else
        stat -c %Y "$file" 2>/dev/null || echo 0
    fi
}

# Get usage token from keychain (macOS) or credentials file
get_usage_token() {
    local now_ts=$(now)

    # Check token cache
    if [[ -f "$TOKEN_CACHE_FILE" ]]; then
        local cache_age=$((now_ts - $(file_mtime "$TOKEN_CACHE_FILE")))
        if [[ $cache_age -lt $TOKEN_CACHE_MAX_AGE ]]; then
            cat "$TOKEN_CACHE_FILE" 2>/dev/null && return 0
        fi
    fi

    local token=""

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: read from keychain
        local keychain_data
        keychain_data=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
        token=$(echo "$keychain_data" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    else
        # Non-macOS: read from credentials file
        local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
        [[ -f "$cred_file" ]] || return 1
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)
    fi

    [[ -n "$token" && "$token" != "null" ]] || return 1

    # Cache the token
    ensure_cache_dir
    echo "$token" > "$TOKEN_CACHE_FILE" 2>/dev/null

    echo "$token"
}

# Read active lock file
read_active_lock() {
    local now_ts=$(now)

    [[ -f "$LOCK_FILE" ]] || return 1

    # Try JSON-based lock first
    local lock_data
    lock_data=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$lock_data" ]]; then
        local blocked_until error
        blocked_until=$(echo "$lock_data" | jq -r '.blockedUntil // empty' 2>/dev/null)
        error=$(echo "$lock_data" | jq -r '.error // "timeout"' 2>/dev/null)

        if [[ -n "$blocked_until" && "$blocked_until" =~ ^[0-9]+$ ]]; then
            if [[ $blocked_until -gt $now_ts ]]; then
                echo "$error:$blocked_until"
                return 0
            fi
            return 1
        fi
    fi

    # Fall back to mtime-based lock
    local lock_mtime=$(file_mtime "$LOCK_FILE")
    local blocked_until=$((lock_mtime + LOCK_MAX_AGE))

    if [[ $blocked_until -gt $now_ts ]]; then
        echo "timeout:$blocked_until"
        return 0
    fi

    return 1
}

# Write lock file
write_lock() {
    local blocked_until="$1"
    local error="${2:-timeout}"

    ensure_cache_dir
    echo "{\"blockedUntil\":$blocked_until,\"error\":\"$error\"}" > "$LOCK_FILE" 2>/dev/null
}

# Parse Retry-After header (supports both seconds and HTTP-date)
parse_retry_after() {
    local retry_after="$1"
    local now_ms=$(($(date +%s) * 1000))

    [[ -z "$retry_after" ]] && return 1

    # If it's just a number (seconds)
    if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        [[ $retry_after -gt 0 ]] && echo "$retry_after" && return 0
        return 1
    fi

    # Try parsing as HTTP-date
    local retry_at_ms
    if [[ "$OSTYPE" == "darwin"* ]]; then
        retry_at_ms=$(date -j -f "%a, %d %b %Y %H:%M:%S %Z" "$retry_after" +%s 2>/dev/null)
    else
        retry_at_ms=$(date -d "$retry_after" +%s 2>/dev/null)
    fi

    [[ -n "$retry_at_ms" ]] || return 1

    local retry_after_seconds=$(( (retry_at_ms - now_ms / 1000) ))
    [[ $retry_after_seconds -gt 0 ]] && echo "$retry_after_seconds" && return 0

    return 1
}

# Fetch from API
fetch_from_api() {
    local token="$1"
    local response_file=$(mktemp)
    local headers_file=$(mktemp)

    # Make API call
    local http_code
    http_code=$(curl -s -m "$USAGE_API_TIMEOUT" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -w "%{http_code}" \
        -o "$response_file" \
        -D "$headers_file" \
        "https://${USAGE_API_HOST}${USAGE_API_PATH}" 2>/dev/null)

    local result=""

    if [[ "$http_code" == "200" ]]; then
        local body
        body=$(cat "$response_file" 2>/dev/null)
        if [[ -n "$body" ]]; then
            result="success:$body"
        else
            result="error"
        fi
    elif [[ "$http_code" == "429" ]]; then
        local retry_after
        retry_after=$(grep -i "^retry-after:" "$headers_file" | sed 's/^retry-after: *//i' | tr -d '\r\n' 2>/dev/null)
        local retry_seconds
        retry_seconds=$(parse_retry_after "$retry_after")
        retry_seconds=${retry_seconds:-$DEFAULT_RATE_LIMIT_BACKOFF}
        result="rate-limited:$retry_seconds"
    else
        result="error"
    fi

    rm -f "$response_file" "$headers_file"
    echo "$result"
}

# Parse API response to UsageData format
parse_api_response() {
    local body="$1"

    jq -n --argjson data "$body" '{
        sessionUsage: $data.five_hour.utilization,
        sessionResetAt: $data.five_hour.resets_at,
        weeklyUsage: $data.seven_day.utilization,
        weeklyResetAt: $data.seven_day.resets_at,
        extraUsageEnabled: $data.extra_usage.is_enabled,
        extraUsageLimit: $data.extra_usage.monthly_limit,
        extraUsageUsed: $data.extra_usage.used_credits,
        extraUsageUtilization: $data.extra_usage.utilization
    }' 2>/dev/null
}

# Read stale cache
read_stale_cache() {
    [[ -f "$CACHE_FILE" ]] || return 1
    cat "$CACHE_FILE" 2>/dev/null
}

# Create error response
create_error_response() {
    local error="$1"
    echo "{\"error\":\"$error\"}"
}

# Main function to fetch usage data
fetch_usage_data() {
    local now_ts=$(now)

    # Check file cache first
    if [[ -f "$CACHE_FILE" ]]; then
        local cache_age=$((now_ts - $(file_mtime "$CACHE_FILE")))
        if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
            local cached_data
            cached_data=$(cat "$CACHE_FILE" 2>/dev/null)
            if [[ -n "$cached_data" ]]; then
                local has_error
                has_error=$(echo "$cached_data" | jq -r '.error // empty' 2>/dev/null)
                if [[ -z "$has_error" ]]; then
                    echo "$cached_data"
                    return 0
                fi
            fi
        fi
    fi

    # Get token
    local token
    token=$(get_usage_token)
    if [[ -z "$token" ]]; then
        local stale
        stale=$(read_stale_cache)
        if [[ -n "$stale" ]]; then
            local has_error
            has_error=$(echo "$stale" | jq -r '.error // empty' 2>/dev/null)
            if [[ -z "$has_error" ]]; then
                echo "$stale"
                return 0
            fi
        fi
        create_error_response "no-credentials"
        return 1
    fi

    # Check for active lock
    local lock_info
    if lock_info=$(read_active_lock); then
        local error="${lock_info%%:*}"
        local stale
        stale=$(read_stale_cache)
        if [[ -n "$stale" ]]; then
            local has_error
            has_error=$(echo "$stale" | jq -r '.error // empty' 2>/dev/null)
            if [[ -z "$has_error" ]]; then
                echo "$stale"
                return 0
            fi
        fi
        create_error_response "$error"
        return 1
    fi

    # Create lock
    write_lock $((now_ts + LOCK_MAX_AGE)) "timeout"

    # Fetch from API
    local api_result
    api_result=$(fetch_from_api "$token")

    local result_type="${api_result%%:*}"
    local result_value="${api_result#*:}"

    case "$result_type" in
        success)
            local usage_data
            usage_data=$(parse_api_response "$result_value")
            if [[ -z "$usage_data" ]]; then
                local stale
                stale=$(read_stale_cache)
                if [[ -n "$stale" ]]; then
                    local has_error
                    has_error=$(echo "$stale" | jq -r '.error // empty' 2>/dev/null)
                    if [[ -z "$has_error" ]]; then
                        echo "$stale"
                        return 0
                    fi
                fi
                create_error_response "parse-error"
                return 1
            fi

            # Validate we got actual data
            local has_session has_weekly
            has_session=$(echo "$usage_data" | jq -r '.sessionUsage // empty' 2>/dev/null)
            has_weekly=$(echo "$usage_data" | jq -r '.weeklyUsage // empty' 2>/dev/null)

            if [[ -z "$has_session" && -z "$has_weekly" ]]; then
                local stale
                stale=$(read_stale_cache)
                if [[ -n "$stale" ]]; then
                    local has_error
                    has_error=$(echo "$stale" | jq -r '.error // empty' 2>/dev/null)
                    if [[ -z "$has_error" ]]; then
                        echo "$stale"
                        return 0
                    fi
                fi
                create_error_response "parse-error"
                return 1
            fi

            # Save to cache
            ensure_cache_dir
            echo "$usage_data" > "$CACHE_FILE" 2>/dev/null

            echo "$usage_data"
            return 0
            ;;
        rate-limited)
            write_lock $((now_ts + result_value)) "rate-limited"
            local stale
            stale=$(read_stale_cache)
            if [[ -n "$stale" ]]; then
                local has_error
                has_error=$(echo "$stale" | jq -r '.error // empty' 2>/dev/null)
                if [[ -z "$has_error" ]]; then
                    echo "$stale"
                    return 0
                fi
            fi
            create_error_response "rate-limited"
            return 1
            ;;
        *)
            local stale
            stale=$(read_stale_cache)
            if [[ -n "$stale" ]]; then
                local has_error
                has_error=$(echo "$stale" | jq -r '.error // empty' 2>/dev/null)
                if [[ -z "$has_error" ]]; then
                    echo "$stale"
                    return 0
                fi
            fi
            create_error_response "api-error"
            return 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fetch_usage_data
fi
