#!/bin/bash

CONFIG_LOADED=false

parse_toml_value() {
    local file="$1"
    local section="$2"
    local key="$3"

    awk -v section="$section" -v key="$key" '
        BEGIN { in_section = 0 }
        /^\[/ {
            gsub(/^\[[ \t]*/, "")
            gsub(/[ \t]*\].*$/, "")
            in_section = ($0 == section) ? 1 : 0
            next
        }
        in_section && /^[ \t]*#/ { next }
        in_section {
            split($0, parts, "=")
            k = parts[1]
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k == key) {
                val = substr($0, index($0, "=") + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", val)
                gsub(/^"/, "", val)
                gsub(/"[ \t]*$/, "", val)
                print val
                exit
            }
        }
    ' "$file"
}

load_ralph_config() {
    local config_file="$1"
    local ralph_dir="$2"

    if [ ! -f "$config_file" ]; then
        echo "Config file not found: $config_file" >&2
        return 1
    fi

    local project_workdir
    project_workdir=$(parse_toml_value "$config_file" "project" "workingDirectory")
    local base_dir="${project_workdir:-$ralph_dir}"

    local prd_path
    prd_path=$(parse_toml_value "$config_file" "prd" "path")
    [ -n "$prd_path" ] && PRD_FILE="$base_dir/$prd_path"

    local prd_backup
    prd_backup=$(parse_toml_value "$config_file" "prd" "backup")
    [ -n "$prd_backup" ] && PRD_BACKUP="$base_dir/$prd_backup"

    local prd_prompt
    prd_prompt=$(parse_toml_value "$config_file" "prd" "prompt")
    [ -n "$prd_prompt" ] && PROMPT_FILE="$base_dir/$prd_prompt"

    local prd_guardrails
    prd_guardrails=$(parse_toml_value "$config_file" "prd" "guardrails")
    [ -n "$prd_guardrails" ] && GUARDRAILS_FILE="$base_dir/$prd_guardrails"

    local prd_progress
    prd_progress=$(parse_toml_value "$config_file" "prd" "progress")
    [ -n "$prd_progress" ] && PROGRESS_FILE="$base_dir/$prd_progress"

    LEGACY_SERVICE_HEALTH=$(parse_toml_value "$config_file" "services.legacy" "health")
    LEGACY_SERVICE_PORT=$(parse_toml_value "$config_file" "services.legacy" "port")
    LEGACY_SERVICE_START=$(parse_toml_value "$config_file" "services.legacy" "start")
    LEGACY_SERVICE_STOP=$(parse_toml_value "$config_file" "services.legacy" "stop")
    LEGACY_SERVICE_WORKDIR=$(parse_toml_value "$config_file" "services.legacy" "workingDirectory")
    LEGACY_SERVICE_NAME=$(parse_toml_value "$config_file" "services.legacy" "name")
    LEGACY_SERVICE_OPTIONAL=$(parse_toml_value "$config_file" "services.legacy" "optional")
    LEGACY_SERVICE_TYPE=$(parse_toml_value "$config_file" "services.legacy" "type")
    LEGACY_SERVICE_MAX_WAIT=$(parse_toml_value "$config_file" "services.legacy" "maxStartWait")

    NEW_SERVICE_HEALTH=$(parse_toml_value "$config_file" "services.new" "health")
    NEW_SERVICE_PORT=$(parse_toml_value "$config_file" "services.new" "port")
    NEW_SERVICE_START=$(parse_toml_value "$config_file" "services.new" "start")
    NEW_SERVICE_STOP=$(parse_toml_value "$config_file" "services.new" "stop")
    NEW_SERVICE_WORKDIR=$(parse_toml_value "$config_file" "services.new" "workingDirectory")
    NEW_SERVICE_NAME=$(parse_toml_value "$config_file" "services.new" "name")
    NEW_SERVICE_OPTIONAL=$(parse_toml_value "$config_file" "services.new" "optional")
    NEW_SERVICE_TYPE=$(parse_toml_value "$config_file" "services.new" "type")
    NEW_SERVICE_BUILD=$(parse_toml_value "$config_file" "services.new" "buildCommand")
    NEW_SERVICE_CONTAINER=$(parse_toml_value "$config_file" "services.new" "containerName")
    NEW_SERVICE_IMAGE=$(parse_toml_value "$config_file" "services.new" "imageName")
    NEW_SERVICE_MAX_WAIT=$(parse_toml_value "$config_file" "services.new" "maxStartWait")

    local test_cmd
    test_cmd=$(parse_toml_value "$config_file" "test" "command")
    [ -n "$test_cmd" ] && CONFIG_TEST_COMMAND="$test_cmd"

    CONFIG_LOADED=true
    return 0
}

check_service_health() {
    local health_url="$1"
    if [ -z "$health_url" ]; then
        return 0
    fi
    local status_code
    status_code=$(curl -s -o /dev/null -w '%{http_code}' "$health_url" --max-time 5 2>/dev/null)
    if [ "$status_code" = "200" ] || [ "$status_code" = "204" ]; then
        return 0
    fi
    return 1
}

wait_for_service_health() {
    local service_name="$1"
    local health_url="$2"
    local max_wait="${3:-30}"
    local elapsed=0
    local interval=3

    while [ $elapsed -lt $max_wait ]; do
        if check_service_health "$health_url"; then
            echo "  $service_name is healthy after ${elapsed}s" >&2
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        printf "\r  Waiting for $service_name... ${elapsed}s/${max_wait}s    " >&2
    done
    echo "" >&2
    echo "  $service_name failed to start after ${max_wait}s" >&2
    return 1
}

start_config_service() {
    local service_name="$1"
    local start_cmd="$2"
    local workdir="$3"
    local health_url="$4"
    local max_wait="${5:-30}"
    local service_type="${6:-}"
    local build_cmd="${7:-}"
    local stop_cmd="${8:-}"
    local container_name="${9:-}"

    echo "  $service_name is DOWN, attempting auto-start..." >&2

    if [ -n "$stop_cmd" ] && [ -n "$workdir" ]; then
        echo "  Stopping stale $service_name..." >&2
        (cd "$workdir" && eval "$stop_cmd") 2>/dev/null
        sleep 2
    fi

    if [ "$service_type" = "docker" ] && [ -n "$build_cmd" ] && [ -n "$workdir" ]; then
        echo "  Building Docker image for $service_name..." >&2
        if ! (cd "$workdir" && eval "$build_cmd") >&2; then
            echo "  Docker build FAILED for $service_name" >&2
            return 1
        fi
        echo "  Docker build complete for $service_name" >&2
    fi

    if [ -n "$start_cmd" ] && [ -n "$workdir" ]; then
        echo "  Starting $service_name..." >&2
        (cd "$workdir" && eval "$start_cmd") >&2
        local start_exit=$?
        if [ $start_exit -ne 0 ]; then
            echo "  Start command failed (exit $start_exit) for $service_name" >&2
            return 1
        fi
    fi

    wait_for_service_health "$service_name" "$health_url" "$max_wait"
}

ensure_single_service_running() {
    local service_name="$1"
    local health_url="$2"
    local port="$3"
    local start_cmd="$4"
    local workdir="$5"
    local is_optional="$6"
    local max_wait="$7"
    local service_type="$8"
    local build_cmd="$9"
    local stop_cmd="${10}"
    local container_name="${11}"

    if [ -z "$health_url" ]; then
        return 0
    fi

    if check_service_health "$health_url"; then
        return 0
    fi

    if [ -n "$start_cmd" ]; then
        if start_config_service "$service_name" "$start_cmd" "$workdir" \
            "$health_url" "${max_wait:-30}" "$service_type" "$build_cmd" \
            "$stop_cmd" "$container_name"; then
            return 0
        fi
    fi

    echo "  Service $service_name is not responding on port $port (health: $health_url)" >&2
    if [ "$is_optional" = "true" ]; then
        echo "  (optional, continuing)" >&2
        return 0
    fi
    return 1
}

ensure_config_services_running() {
    if [ -n "$LEGACY_SERVICE_HEALTH" ]; then
        if ! ensure_single_service_running \
            "${LEGACY_SERVICE_NAME:-legacy}" \
            "$LEGACY_SERVICE_HEALTH" \
            "${LEGACY_SERVICE_PORT:-3200}" \
            "$LEGACY_SERVICE_START" \
            "$LEGACY_SERVICE_WORKDIR" \
            "$LEGACY_SERVICE_OPTIONAL" \
            "${LEGACY_SERVICE_MAX_WAIT:-30}" \
            "$LEGACY_SERVICE_TYPE" \
            "" \
            "$LEGACY_SERVICE_STOP" \
            ""; then
            return 1
        fi
    fi

    if [ -n "$NEW_SERVICE_HEALTH" ]; then
        if ! ensure_single_service_running \
            "${NEW_SERVICE_NAME:-new}" \
            "$NEW_SERVICE_HEALTH" \
            "${NEW_SERVICE_PORT:-3201}" \
            "$NEW_SERVICE_START" \
            "$NEW_SERVICE_WORKDIR" \
            "$NEW_SERVICE_OPTIONAL" \
            "${NEW_SERVICE_MAX_WAIT:-30}" \
            "$NEW_SERVICE_TYPE" \
            "$NEW_SERVICE_BUILD" \
            "$NEW_SERVICE_STOP" \
            "$NEW_SERVICE_CONTAINER"; then
            return 1
        fi
    fi

    return 0
}

rebuild_and_restart_docker_service() {
    if [ "$NEW_SERVICE_TYPE" != "docker" ]; then
        return 0
    fi
    if [ -z "$NEW_SERVICE_BUILD" ] || [ -z "$NEW_SERVICE_WORKDIR" ]; then
        return 0
    fi

    echo "  Rebuilding Docker image for ${NEW_SERVICE_NAME:-new}..." >&2
    if [ -n "$NEW_SERVICE_STOP" ]; then
        (cd "$NEW_SERVICE_WORKDIR" && eval "$NEW_SERVICE_STOP") 2>/dev/null
        sleep 2
    fi

    if ! (cd "$NEW_SERVICE_WORKDIR" && eval "$NEW_SERVICE_BUILD") >&2; then
        echo "  Docker rebuild FAILED" >&2
        return 1
    fi

    if [ -n "$NEW_SERVICE_START" ]; then
        (cd "$NEW_SERVICE_WORKDIR" && eval "$NEW_SERVICE_START") >&2
    fi

    wait_for_service_health "${NEW_SERVICE_NAME:-new}" "$NEW_SERVICE_HEALTH" "${NEW_SERVICE_MAX_WAIT:-60}"
}
