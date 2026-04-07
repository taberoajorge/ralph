#!/bin/bash

set +e

RALPH_DIR="$(cd "$(dirname "$0")" && pwd)"
MAX_ITERATIONS=${MAX_ITERATIONS:-9999}
POLL_INTERVAL=${POLL_INTERVAL:-300}
ITERATION=0

LAST_REBASE_FILE="$RALPH_DIR/.ralph_last_rebase"

ACTION=""
CURSOR_MODEL_ARG=""
CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        watch)
            ACTION="watch"
            shift
            ;;
        status)
            ACTION="status"
            shift
            ;;
        reset)
            ACTION="reset"
            shift
            ;;
        --model)
            CURSOR_MODEL_ARG="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            MAX_ITERATIONS=$1
            shift
            ;;
    esac
done

PRD_FILE="${PRD_FILE:-$RALPH_DIR/prd.json}"
PRD_BACKUP="${PRD_BACKUP:-$RALPH_DIR/prd.backup}"
PROMPT_FILE="${PROMPT_FILE:-$RALPH_DIR/prompt.md}"
PROGRESS_FILE="${PROGRESS_FILE:-$RALPH_DIR/progress.txt}"
GUARDRAILS_FILE="${GUARDRAILS_FILE:-$RALPH_DIR/guardrails.md}"
CONFIG_LOADED=false

if [ -n "$CONFIG_FILE" ]; then
    if [[ "$CONFIG_FILE" != /* ]]; then
        CONFIG_FILE="$RALPH_DIR/$CONFIG_FILE"
    fi
    source "$RALPH_DIR/ralph-config.sh"
    if ! load_ralph_config "$CONFIG_FILE" "$RALPH_DIR"; then
        echo "Failed to load config: $CONFIG_FILE" >&2
        exit 1
    fi
fi

CURSOR_MODEL="${CURSOR_MODEL_ARG:-${CURSOR_MODEL:-claude-4.6-opus-max-thinking}}"
CURSOR_FALLBACK_MODEL="${CURSOR_FALLBACK_MODEL:-claude-4.6-sonnet-medium-thinking}"

MAX_RETRIES=${MAX_RETRIES:-5}
INITIAL_BACKOFF=${INITIAL_BACKOFF:-30}
MAX_BACKOFF=${MAX_BACKOFF:-600}
RATE_LIMIT_WAIT=${RATE_LIMIT_WAIT:-120}

GUTTER_THRESHOLD=${GUTTER_THRESHOLD:-3}

ERROR_LOG="$RALPH_DIR/error.log"
ACTIVITY_LOG="$RALPH_DIR/activity.log"
STATE_FILE="$RALPH_DIR/.ralph_state"
PAUSE_FILE="$RALPH_DIR/.ralph-pause"
DONE_FILE="$RALPH_DIR/.ralph-done"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm" $hours $minutes
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $message" >> "$ERROR_LOG"
    echo -e "${RED}x $message${NC}"
}

log_info() {
    local message="$1"
    echo -e "${CYAN}i $message${NC}"
}

log_success() {
    local message="$1"
    echo -e "${GREEN}v $message${NC}"
}

log_warning() {
    local message="$1"
    echo -e "${YELLOW}! $message${NC}"
}

log_activity() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$ACTIVITY_LOG"
}

watch_mode() {
    echo -e "${CYAN}===============================================${NC}"
    echo -e "  Ralph (Cursor) Watch Mode"
    echo -e "${CYAN}===============================================${NC}"
    echo ""
    log_info "Monitoring logs in real time..."
    echo -e "${GRAY}   Press Ctrl+C to exit${NC}"
    echo ""

    if [ -f "$ACTIVITY_LOG" ]; then
        tail -f "$ACTIVITY_LOG" "$ERROR_LOG" 2>/dev/null
    else
        log_warning "No logs yet. Run Ralph first."
    fi
    exit 0
}

status_mode() {
    echo -e "${CYAN}===============================================${NC}"
    echo -e "  Ralph (Cursor) Status"
    echo -e "${CYAN}===============================================${NC}"
    echo ""

    if [ -f "$PRD_FILE" ]; then
        local total=$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo "0")
        local passed=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE" 2>/dev/null || echo "0")
        local pending=$((total - passed))

        echo -e "   Stories: ${GREEN}$passed${NC} / $total completed"
        echo -e "   Pending: ${YELLOW}$pending${NC}"
    fi

    if [ -f "$STATE_FILE" ]; then
        echo ""
        echo -e "   ${YELLOW}Active state found${NC}"
        cat "$STATE_FILE" | while read line; do echo "     $line"; done
    fi

    if [ -f "$PAUSE_FILE" ]; then
        echo ""
        echo -e "   ${YELLOW}Ralph is PAUSED${NC}"
        echo "     Remove $PAUSE_FILE to resume"
    fi

    if [ -f "$ERROR_LOG" ]; then
        local error_count=$(grep -c "^\[" "$ERROR_LOG" 2>/dev/null || echo "0")
        [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0
        echo ""
        echo -e "   Errors logged: $error_count"
    fi

    if [ -f "$GUARDRAILS_FILE" ]; then
        local guardrail_count=$(grep -c "^### Sign:" "$GUARDRAILS_FILE" 2>/dev/null || echo "0")
        [[ "$guardrail_count" =~ ^[0-9]+$ ]] || guardrail_count=0
        echo -e "   Active guardrails: $guardrail_count"
    fi

    echo ""
    echo -e "${CYAN}Model:${NC}"
    echo -e "   ${GREEN}* $CURSOR_MODEL (active)${NC}"
    echo -e "   ${GRAY}  $CURSOR_FALLBACK_MODEL (fallback)${NC}"

    local auth_status
    auth_status=$(agent status 2>&1 | head -3)
    echo ""
    echo -e "${CYAN}Auth:${NC}"
    echo "   $auth_status"

    if [ -f "$PRD_FILE" ]; then
        local status_wd
        status_wd=$(jq -r '.workingDirectory // empty' "$PRD_FILE" 2>/dev/null)
        if [ -n "$status_wd" ] && [ "$status_wd" != "null" ] && [ -d "$status_wd/.git" ]; then
            echo ""
            local commits=$(git -C "$status_wd" log --oneline --since="today" 2>/dev/null | wc -l | tr -d ' ')
            echo -e "   Commits today: $commits"
        fi
    fi

    echo ""
    exit 0
}

reset_mode() {
    echo -e "${YELLOW}! Resetting Ralph state...${NC}"
    rm -f "$STATE_FILE" "$PAUSE_FILE" "$DONE_FILE"
    echo -e "${GREEN}v State reset${NC}"
    exit 0
}

case "$ACTION" in
    watch)
        watch_mode
        ;;
    status)
        status_mode
        ;;
    reset)
        reset_mode
        ;;
esac

echo -e "${CYAN}===============================================${NC}"
echo -e "  Ralph (Cursor) - Autonomous AI Agent"
echo -e "${CYAN}===============================================${NC}"
echo ""
echo "   Max iterations: $MAX_ITERATIONS"
echo "   Poll interval: ${POLL_INTERVAL}s ($(format_duration $POLL_INTERVAL))"
echo "   Model: $CURSOR_MODEL"
echo "   Fallback: $CURSOR_FALLBACK_MODEL"
echo "   Config dir: $RALPH_DIR"
echo ""

echo -e "${GRAY}Error handling:${NC}"
echo -e "${GRAY}   Max retries: $MAX_RETRIES | Gutter threshold: $GUTTER_THRESHOLD${NC}"
echo -e "${GRAY}   Rate limit wait: ${RATE_LIMIT_WAIT}s${NC}"
echo ""
echo -e "${GRAY}Files:${NC}"
echo -e "${GRAY}   PRD: $PRD_FILE${NC}"
echo -e "${GRAY}   Activity: $ACTIVITY_LOG${NC}"
echo -e "${GRAY}   Errors: $ERROR_LOG${NC}"
echo -e "${GRAY}   Cursor output: $RALPH_DIR/cursor_output.log${NC}"
echo -e "${GRAY}   Cursor last msg: $RALPH_DIR/cursor_last_message.txt${NC}"
echo -e "${GRAY}   Guardrails: $GUARDRAILS_FILE${NC}"
echo ""

if [ -f "$ERROR_LOG" ] && [ $(wc -l < "$ERROR_LOG" 2>/dev/null || echo 0) -gt 1000 ]; then
    mv "$ERROR_LOG" "$ERROR_LOG.old"
    log_info "Error log rotated"
fi
echo "# Ralph Error Log - Started $(date)" >> "$ERROR_LOG"

if [ ! -f "$ACTIVITY_LOG" ]; then
    echo "# Ralph Activity Log" > "$ACTIVITY_LOG"
fi
log_activity "=== Ralph (Cursor) session started ==="

if [ ! -f "$GUARDRAILS_FILE" ]; then
    cat > "$GUARDRAILS_FILE" << 'EOF'
# Guardrails (Signs)

Lessons learned from previous iterations. The agent MUST read this FIRST.

## Active Guardrails

(None yet - will be added as errors are encountered)

---

## How to Add a Guardrail

When something fails repeatedly, add a sign:

### Sign: [Short description]
- **Trigger**: [When it applies]
- **Instruction**: [What to do instead]
- **Added after**: Iteration N - [what happened]

EOF
    log_activity "Created guardrails.md"
fi

if ! command -v agent &> /dev/null; then
    log_error "Cursor Agent CLI not found. Install with: curl https://cursor.com/install -fsSL | bash"
    exit 1
fi

CURSOR_VERSION=$(agent --version 2>/dev/null || echo "unknown")
log_success "Using Cursor Agent CLI ($CURSOR_VERSION) with model $CURSOR_MODEL"

CURSOR_AUTH=$(agent status 2>&1)
if echo "$CURSOR_AUTH" | grep -qiE "not logged in|no.*auth|unauthenticated"; then
    if [ -z "$CURSOR_API_KEY" ]; then
        log_warning "Not authenticated. Run 'agent login' or set CURSOR_API_KEY."
        log_info "Attempting to continue - agent may use cached session."
    else
        log_success "Using CURSOR_API_KEY for authentication"
    fi
else
    log_success "Cursor Agent authenticated"
fi

if [ ! -f "$PRD_FILE" ]; then
    log_error "PRD not found: $PRD_FILE"
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    log_error "Prompt not found: $PROMPT_FILE"
    exit 1
fi

WORK_DIR_FROM_PRD=$(jq -r '.workingDirectory' "$PRD_FILE")
if [ -z "$WORK_DIR_FROM_PRD" ] || [ "$WORK_DIR_FROM_PRD" = "null" ]; then
    log_error "workingDirectory not set in PRD"
    exit 1
fi

WORK_DIR="$WORK_DIR_FROM_PRD"

if [ ! -d "$WORK_DIR_FROM_PRD" ]; then
    log_error "workingDirectory does not exist: $WORK_DIR_FROM_PRD"
    exit 1
fi

PROJECT=$(jq -r '.project' "$PRD_FILE")
FEATURE=$(jq -r '.feature' "$PRD_FILE")
echo -e "Project: ${BLUE}$PROJECT${NC}"
echo -e "Feature: ${BLUE}$FEATURE${NC}"
echo -e "Working dir: ${GRAY}$WORK_DIR${NC}"

BRANCH_DISPLAY=$(jq -r '.branchName // "unknown"' "$PRD_FILE")
echo -e "Branch: ${GREEN}$BRANCH_DISPLAY${NC} -> origin/main"

if [ -f "$LAST_REBASE_FILE" ]; then
    LAST_HASH=$(cat "$LAST_REBASE_FILE" 2>/dev/null)
    echo -e "Last rebase: ${GRAY}${LAST_HASH:0:12}${NC}"
else
    echo -e "Last rebase: ${YELLOW}(first run)${NC}"
fi
echo ""

if [ ! -f "$PROGRESS_FILE" ]; then
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "# Feature: $FEATURE" >> "$PROGRESS_FILE"
    echo "# Started: $(date)" >> "$PROGRESS_FILE"
    echo "" >> "$PROGRESS_FILE"
fi

INITIAL_COMMIT=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "")

parse_error_type() {
    local error_output="$1"

    if echo "$error_output" | grep -qiE "model.?not.?found|model.?unavailable|does.?not.?exist|ModelNotFoundError"; then
        echo "MODEL_ERROR"
    elif echo "$error_output" | grep -qiE "Cannot read properties of undefined|unexpected critical error|TypeError:|internal.*error"; then
        echo "SERVER_ERROR"
    elif echo "$error_output" | grep -qiE "insufficient.?quota|billing|payment|exceeded.?your.?current.?quota|quota.?exceeded|usage.?limit"; then
        echo "QUOTA_EXHAUSTED"
    elif echo "$error_output" | grep -qiE "429|rate.?limit|too.?many.?requests|Rate limit reached|requests.?per.?min|capacity.?exhausted|RESOURCE_EXHAUSTED|No capacity available"; then
        echo "RATE_LIMIT"
    elif echo "$error_output" | grep -qiE "Terminated|SIGTERM|SIGKILL|signal|killed"; then
        echo "TERMINATED"
    elif echo "$error_output" | grep -qiE "invalid.?api.?key|401|unauthorized|UNAUTHENTICATED|authentication|not logged in"; then
        echo "AUTH_ERROR"
    elif echo "$error_output" | grep -qiE "400|invalid.?request|bad.?request|invalid.?argument"; then
        echo "INVALID_REQUEST"
    elif echo "$error_output" | grep -qiE "500|502|503|504|server.?error|overloaded"; then
        echo "SERVER_ERROR"
    elif echo "$error_output" | grep -qiE "ECONNREFUSED|ETIMEDOUT|ENOTFOUND|network|connection|timeout|fetch.?failed"; then
        echo "NETWORK_ERROR"
    elif echo "$error_output" | grep -qiE "context.?length|context.?window|token.?limit|maximum.?context|too.?long"; then
        echo "CONTEXT_LENGTH"
    else
        echo "UNKNOWN"
    fi
}

calculate_backoff() {
    local attempt=$1
    local base_wait=$2
    local backoff=$((base_wait * (2 ** (attempt - 1))))
    [ $backoff -gt $MAX_BACKOFF ] && backoff=$MAX_BACKOFF
    local jitter=$((RANDOM % 31))
    echo $((backoff + jitter))
}

wait_with_countdown() {
    local seconds=$1
    local reason="$2"

    echo ""
    echo -e "${YELLOW}Waiting: $reason${NC}"
    echo "   Duration: $(format_duration $seconds)..."
    echo "   Resume at: $(date -v+${seconds}S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "+${seconds} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "in $(format_duration $seconds)")"
    echo ""

    while [ $seconds -gt 0 ]; do
        if [ -f "$PAUSE_FILE" ]; then
            echo -e "\n${YELLOW}Paused by .ralph-pause file${NC}"
            while [ -f "$PAUSE_FILE" ]; do
                sleep 5
            done
            echo -e "${GREEN}Resuming...${NC}"
        fi

        if [ $seconds -gt 60 ]; then
            printf "\r   %s remaining... (touch .ralph-pause to pause)     " "$(format_duration $seconds)"
            sleep 60
            seconds=$((seconds - 60))
        else
            printf "\r   %s remaining...                                       " "$(format_duration $seconds)"
            sleep 1
            seconds=$((seconds - 1))
        fi
    done
    printf "\r   ${GREEN}Continuing...${NC}                                          \n"
    echo ""
}

wait_for_rate_limit() {
    local wait_time=$1
    local resume_time=$(($(date +%s) + wait_time))

    echo "WAITING_FOR_RATE_LIMIT" > "$STATE_FILE"
    echo "RESUME_TIME=$resume_time" >> "$STATE_FILE"
    echo "ITERATION=$ITERATION" >> "$STATE_FILE"

    log_activity "Rate limited - waiting $(format_duration $wait_time)"
    wait_with_countdown $wait_time "Rate limit - waiting for reset"
    rm -f "$STATE_FILE"
}

check_resume_state() {
    if [ -f "$STATE_FILE" ]; then
        local state=$(head -1 "$STATE_FILE")
        if [ "$state" = "WAITING_FOR_RATE_LIMIT" ]; then
            source "$STATE_FILE"
            local now=$(date +%s)

            if [ -n "$RESUME_TIME" ] && [ $now -lt $RESUME_TIME ]; then
                local remaining=$((RESUME_TIME - now))
                log_info "Detected previous state - time remaining: $(format_duration $remaining)"
                wait_for_rate_limit $remaining
                [ -n "$ITERATION" ] && log_info "Resuming from iteration $ITERATION"
            else
                log_success "Wait time has passed - continuing"
                rm -f "$STATE_FILE"
            fi
        fi
    fi
}

check_pause() {
    if [ -f "$PAUSE_FILE" ]; then
        echo -e "\n${YELLOW}PAUSED - Remove .ralph-pause to continue${NC}"
        log_activity "Paused by .ralph-pause file"
        while [ -f "$PAUSE_FILE" ]; do
            sleep 5
        done
        echo -e "${GREEN}Resuming...${NC}"
        log_activity "Resumed"
    fi
}

check_done() {
    if [ -f "$DONE_FILE" ]; then
        log_success ".ralph-done detected - finishing"
        rm -f "$DONE_FILE"
        return 0
    fi
    return 1
}

check_gutter() {
    local story_id="$1"

    if [ ! -f "$ERROR_LOG" ]; then
        return 1
    fi

    local error_count=$(grep -c "$story_id" "$ERROR_LOG" 2>/dev/null || echo "0")
    [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0

    if [ "$error_count" -ge "$GUTTER_THRESHOLD" ]; then
        return 0
    fi
    return 1
}

add_guardrail() {
    local story_id="$1"
    local error_msg="$2"
    local iteration="$3"

    if grep -q "Sign: Error in $story_id" "$GUARDRAILS_FILE" 2>/dev/null; then
        log_info "Guardrail for $story_id already exists - skipping duplicate"
        return 0
    fi

    cat >> "$GUARDRAILS_FILE" << EOF

### Sign: Error in $story_id
- **Trigger**: When working on this story
- **Instruction**: Review previous errors before attempting - $error_msg
- **Added after**: Iteration $iteration - repeated errors detected

EOF

    log_activity "Added guardrail for story: $story_id"
    log_warning "Guardrail added for: $story_id"
}

get_commits_since_start() {
    if [ -n "$INITIAL_COMMIT" ]; then
        git -C "$WORK_DIR" rev-list "$INITIAL_COMMIT"..HEAD 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

run_ai_agent() {
    local prompt="$1"
    local story_id="$2"
    local attempt=0
    local output_log="$RALPH_DIR/cursor_output.log"
    local last_message_file="$RALPH_DIR/cursor_last_message.txt"
    local prompt_file=$(mktemp)
    local current_model="$CURSOR_MODEL"
    local fallback_triggered=0

    echo "$prompt" > "$prompt_file"

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        [ $attempt -gt 1 ] && log_info "Attempt $attempt of $MAX_RETRIES (model: $current_model)..."

        if [ $fallback_triggered -eq 0 ] && [ $attempt -gt 3 ]; then
            log_warning "Primary model failed 3 times - switching to fallback: $CURSOR_FALLBACK_MODEL"
            current_model="$CURSOR_FALLBACK_MODEL"
            fallback_triggered=1
        fi

        local log_size_before=$(wc -c < "$output_log" 2>/dev/null || echo 0)

        echo "" >> "$output_log"
        echo "=== [$(date '+%H:%M:%S')] Story: $story_id | Model: $current_model | Attempt: $attempt ===" >> "$output_log"

        echo -e "${GRAY}---------------------------------------------${NC}"
        echo -e "${CYAN}[$(date '+%H:%M:%S')] Cursor ($current_model) autonomous mode...${NC}"
        echo -e "${GRAY}---------------------------------------------${NC}"

        rm -f "$last_message_file"

        local agent_stall_timeout=${CURSOR_STALL_TIMEOUT:-600}

        (cd "$WORK_DIR" && agent -p --force \
            --model "$current_model" \
            --output-format stream-json \
            --workspace "$WORK_DIR" \
            --sandbox disabled \
            --approve-mcps \
            "$(cat "$prompt_file")" \
            2>&1) | tee -a "$output_log" &
        local tee_pid=$!

        local agent_pid=""
        for _i in $(seq 1 10); do
            agent_pid=$(pgrep -P $tee_pid 2>/dev/null || pgrep -f "agent.*--print\|agent.*-p.*--force" 2>/dev/null | head -1)
            [ -n "$agent_pid" ] && break
            sleep 1
        done

        local last_size=$(wc -c < "$output_log" 2>/dev/null || echo 0)
        local stall_seconds=0

        while kill -0 $tee_pid 2>/dev/null; do
            sleep 10
            local current_size=$(wc -c < "$output_log" 2>/dev/null || echo 0)
            if [ "$current_size" -eq "$last_size" ]; then
                stall_seconds=$((stall_seconds + 10))
                if [ $stall_seconds -ge $agent_stall_timeout ]; then
                    log_warning "Cursor Agent stalled for ${agent_stall_timeout}s - killing"
                    log_activity "Cursor Agent killed (stalled ${agent_stall_timeout}s, no output)"
                    kill $tee_pid 2>/dev/null
                    pkill -P $tee_pid 2>/dev/null
                    [ -n "$agent_pid" ] && kill $agent_pid 2>/dev/null
                    pkill -f "agent.*-p.*--force" 2>/dev/null
                    sleep 2
                    break
                fi
            else
                stall_seconds=0
                last_size=$current_size
            fi
        done

        wait $tee_pid 2>/dev/null
        local exit_code=$?

        echo -e "${GRAY}---------------------------------------------${NC}"
        echo -e "${CYAN}[$(date '+%H:%M:%S')] Cursor finished (exit: $exit_code)${NC}"
        log_activity "Cursor Agent exited with code $exit_code (story: $story_id, model: $current_model)"

        local log_size_after=$(wc -c < "$output_log" 2>/dev/null || echo 0)
        local attempt_bytes=$((log_size_after - log_size_before))

        local last_msg_preview=""
        if [ $attempt_bytes -gt 0 ]; then
            last_msg_preview=$(tail -c "$attempt_bytes" "$output_log" 2>/dev/null | grep -o '"text":"[^"]\{0,200\}' | tail -1 | sed 's/"text":"//')
            if [ -n "$last_msg_preview" ]; then
                echo "$last_msg_preview" > "$last_message_file"
                log_activity "Cursor last message: ${last_msg_preview:0:200}"
            fi
        fi

        if [ $exit_code -eq 0 ]; then
            local error_output
            error_output=$(tail -c "$attempt_bytes" "$output_log" 2>/dev/null || echo "")
            if echo "$error_output" | grep -qiE "rate.?limit|quota.?exceeded|RESOURCE_EXHAUSTED|No capacity|unauthorized|TypeError:|Cannot read properties"; then
                log_warning "Cursor exited 0 but output contains error: $(parse_error_type "$error_output")"
                exit_code=1
            else
                rm -f "$prompt_file"
                return 0
            fi
        fi

        local error_output
        error_output=$(tail -c "$attempt_bytes" "$output_log" 2>/dev/null || echo "")
        local error_type=$(parse_error_type "$error_output")

        if [ $exit_code -eq 143 ] || [ $exit_code -eq 137 ]; then
            error_type="TERMINATED"
        fi

        log_error "Error in attempt $attempt: $error_type (exit: $exit_code, model: $current_model, story: $story_id)"
        echo "[$(date '+%H:%M:%S')] [$story_id] $error_type (exit: $exit_code, model: $current_model)" >> "$ERROR_LOG"

        case "$error_type" in
            "QUOTA_EXHAUSTED")
                log_error "Cursor quota exhausted - check usage at https://cursor.com/settings"
                local wait_time=$((RATE_LIMIT_WAIT * 2))
                [ $attempt -gt 2 ] && wait_time=$((RATE_LIMIT_WAIT * attempt * 2))
                wait_with_countdown $wait_time "Quota exhausted (Cursor)"
                ;;
            "RATE_LIMIT")
                local wait_time=$RATE_LIMIT_WAIT
                [ $attempt -gt 2 ] && wait_time=$((RATE_LIMIT_WAIT * attempt))
                wait_with_countdown $wait_time "Rate limit reached ($current_model)"
                ;;
            "TERMINATED")
                log_warning "Process terminated by signal - waiting before retry"
                wait_with_countdown 60 "Process terminated (SIGTERM/SIGKILL)"
                ;;
            "AUTH_ERROR")
                log_error "Authentication error - run: agent login"
                log_error "Or set CURSOR_API_KEY environment variable."
                rm -f "$prompt_file"
                return 1
                ;;
            "MODEL_ERROR")
                log_error "Model '$current_model' not available. Run: agent --list-models"
                if [ "$current_model" != "$CURSOR_FALLBACK_MODEL" ]; then
                    log_warning "Switching to fallback model: $CURSOR_FALLBACK_MODEL"
                    current_model="$CURSOR_FALLBACK_MODEL"
                    fallback_triggered=1
                else
                    rm -f "$prompt_file"
                    return 1
                fi
                ;;
            "CONTEXT_LENGTH")
                log_error "Prompt exceeds token limit for $current_model"
                rm -f "$prompt_file"
                return 1
                ;;
            "SERVER_ERROR")
                local wait_time=$(calculate_backoff $attempt $INITIAL_BACKOFF)
                log_warning "Server error - retrying with backoff"
                wait_with_countdown $wait_time "Server error (Cursor)"
                ;;
            *)
                local wait_time=$(calculate_backoff $attempt $INITIAL_BACKOFF)
                wait_with_countdown $wait_time "Error: $error_type"
                ;;
        esac
    done

    log_error "Retries exhausted ($MAX_RETRIES)"
    rm -f "$prompt_file"
    return 1
}

check_resume_state

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    check_pause
    check_done && break

    if [ "$CONFIG_LOADED" = "true" ]; then
        if ! ensure_config_services_running; then
            log_error "Service unavailable (config) - retrying in 30s"
            log_activity "Iteration skipped - config service down"
            sleep 30
            continue
        fi
    fi

    if [ ! -f "$PRD_FILE" ] || ! jq '.' "$PRD_FILE" > /dev/null 2>&1; then
        log_warning "PRD missing or corrupted - restoring from backup"
        if [ -f "$PRD_BACKUP" ]; then
            cp "$PRD_BACKUP" "$PRD_FILE"
            log_success "PRD restored from backup"
        else
            log_error "No backup available - stopping"
            exit 1
        fi
    fi

    TOTAL=$(jq '.userStories | length' "$PRD_FILE")
    PASSED=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE")
    BLOCKED=$(jq '[.userStories[] | select(.blocked == true)] | length' "$PRD_FILE")
    PENDING=$((TOTAL - PASSED - BLOCKED))

    if [ "$PENDING" -le 0 ]; then
        log_success "All stories completed (or blocked)! $PASSED passed, $BLOCKED blocked."
        break
    fi

    NEXT_STORY_ID=$(jq -r '[.userStories[] | select(.passes == false and (.blocked | not))][0].id' "$PRD_FILE")
    if [ -z "$NEXT_STORY_ID" ] || [ "$NEXT_STORY_ID" = "null" ]; then
        log_success "No more actionable stories. Done."
        break
    fi

    ITERATION=$((ITERATION + 1))
    ITER_START=$(date +%s)

    echo ""
    echo -e "${BLUE}===============================================${NC}"
    echo -e "  Iteration $ITERATION"
    echo -e "${BLUE}===============================================${NC}"

    log_activity "=== Iteration $ITERATION started ==="

    echo -e "   Progress: ${GREEN}$PASSED${NC}/$TOTAL | Pending: ${YELLOW}$PENDING${NC} | Blocked: ${GRAY}$BLOCKED${NC}"

    cp "$PRD_FILE" "$PRD_BACKUP"

    NEXT_STORY_TITLE=$(jq -r "[.userStories[] | select(.id == \"$NEXT_STORY_ID\")][0].title" "$PRD_FILE")
    echo -e "   Story: ${CYAN}$NEXT_STORY_TITLE${NC}"

    if check_gutter "$NEXT_STORY_ID"; then
        log_warning "GUTTER DETECTED - This story has failed $GUTTER_THRESHOLD+ times"
        add_guardrail "$NEXT_STORY_ID" "Repeated errors" "$ITERATION"
        echo -e "   ${YELLOW}Consider manual review or skipping this story${NC}"
    fi

    GUARDRAILS_CONTENT=""
    if [ -f "$GUARDRAILS_FILE" ]; then
        GUARDRAILS_CONTENT=$(cat "$GUARDRAILS_FILE")
    fi

    NEXT_STORY_JSON=$(jq '[.userStories[] | select(.passes == false and (.blocked | not))][0]' "$PRD_FILE")

    FULL_PROMPT="$(cat "$PROMPT_FILE" 2>/dev/null || echo "No prompt file found at $PROMPT_FILE")

## GUARDRAILS (READ FIRST!)

$GUARDRAILS_CONTENT

---

IMPORTANT: You have full file system access. You can use bash heredoc syntax freely.

Next story to implement:
$NEXT_STORY_JSON

---
## DYNAMIC CONTEXT (this section changes per iteration)

RALPH_DIR: $RALPH_DIR
WORK_DIR: $WORK_DIR
Current working directory: $WORK_DIR
Config directory: $RALPH_DIR
ITERATION: $ITERATION
"

    echo ""
    log_info "Starting Cursor agent ($CURSOR_MODEL)..."

    HEAD_BEFORE=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "")

    if ! run_ai_agent "$FULL_PROMPT" "$NEXT_STORY_ID"; then
        log_error "Iteration $ITERATION failed"
        log_activity "Iteration $ITERATION failed for story: $NEXT_STORY_ID"

        if grep -q "AUTH_ERROR\|CONTEXT_LENGTH\|MODEL_ERROR" "$ERROR_LOG" 2>/dev/null; then
            log_error "Fatal error - stopping"
            exit 1
        fi

        wait_with_countdown 60 "Pause before continuing"
    fi

    if [ ! -f "$PRD_FILE" ] || ! jq '.' "$PRD_FILE" > /dev/null 2>&1; then
        log_warning "PRD missing or corrupted after iteration - restoring from backup"
        cp "$PRD_BACKUP" "$PRD_FILE"
    fi

    if [ "$CONFIG_LOADED" = "true" ]; then
        HEAD_AFTER=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "")
        if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ] && [ -n "$HEAD_AFTER" ]; then
            CHANGED_COMMITS=$(($(git -C "$WORK_DIR" rev-list "$HEAD_BEFORE".."$HEAD_AFTER" 2>/dev/null | wc -l | tr -d ' ')))
            log_info "Detected $CHANGED_COMMITS new commit(s) after Cursor iteration"
            log_activity "Code changed ($CHANGED_COMMITS commits) - rebuilding Docker service if configured"
            if type rebuild_and_restart_docker_service >/dev/null 2>&1; then
                if rebuild_and_restart_docker_service; then
                    log_success "Docker service rebuilt and restarted"
                else
                    log_warning "Docker rebuild failed - service may be stale"
                fi
            fi
        fi
    fi

    ITER_END=$(date +%s)
    ITER_DURATION=$((ITER_END - ITER_START))
    COMMITS_NOW=$(get_commits_since_start)

    STORY_PASSED=$(jq -r "[.userStories[] | select(.id == \"$NEXT_STORY_ID\")][0].passes" "$PRD_FILE" 2>/dev/null)

    if [ "$STORY_PASSED" = "true" ]; then
        log_success "Story $NEXT_STORY_ID completed!"
    else
        log_warning "Story $NEXT_STORY_ID: agent finished but not marked as passed"
    fi

    log_activity "Iteration $ITERATION completed in $(format_duration $ITER_DURATION) | Commits: $COMMITS_NOW | Story: $NEXT_STORY_ID | Passed: $STORY_PASSED"
    echo -e "${GRAY}   Duration: $(format_duration $ITER_DURATION) | Commits: $COMMITS_NOW${NC}"

    if [ -f "$ERROR_LOG" ]; then
        RECENT_RATE_LIMITS=$(tail -5 "$ERROR_LOG" 2>/dev/null | grep -c "RATE_LIMIT" || echo "0")
        [[ "$RECENT_RATE_LIMITS" =~ ^[0-9]+$ ]] || RECENT_RATE_LIMITS=0
        if [ "$RECENT_RATE_LIMITS" -ge 2 ]; then
            log_warning "Multiple rate limits - extended pause"
            wait_with_countdown 600 "Extended pause for rate limits"
        fi
    fi

    log_info "Cooldown 30s before next iteration..."
    sleep 30
done

echo ""
echo -e "${YELLOW}===============================================${NC}"
echo -e "  Max iterations ($MAX_ITERATIONS) reached"
echo -e "  Total rebase iterations: $ITERATION"
echo -e "${YELLOW}===============================================${NC}"

echo "   Model: $CURSOR_MODEL"
echo "   Fallback: $CURSOR_FALLBACK_MODEL"
echo "   Total commits: $(get_commits_since_start)"
if [ -f "$LAST_REBASE_FILE" ]; then
    echo "   Last successful rebase: $(cat "$LAST_REBASE_FILE")"
fi

if [ -f "$ERROR_LOG" ]; then
    ERROR_COUNT=$(grep -c "^\[" "$ERROR_LOG" 2>/dev/null || echo "0")
    [[ "$ERROR_COUNT" =~ ^[0-9]+$ ]] || ERROR_COUNT=0
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo ""
        echo "Error summary:"
        echo "   Total errors: $ERROR_COUNT"
        grep -oE "RATE_LIMIT|INVALID_REQUEST|SERVER_ERROR|NETWORK_ERROR|QUOTA_EXHAUSTED|AUTH_ERROR|MODEL_ERROR|CONTEXT_LENGTH|UNKNOWN" "$ERROR_LOG" 2>/dev/null | sort | uniq -c | while read count type; do
            echo "    - $type: $count"
        done
    fi
fi

log_activity "=== Session ended after $ITERATION iterations ==="
rm -f "$STATE_FILE"
