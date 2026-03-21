#!/bin/bash

enable_timestamped_output() {
    exec > >(while IFS= read -r line; do
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done) 2>&1
}

enable_timestamped_output

PLUGIN_NAME="power.optimizer"
PLUGIN_MODE_AUTO_OPTIMIZE="auto-optimize"
PLUGIN_MODE_STARTUP_AUTO_OPTIMIZE="auto-optimize-startup"
PLUGIN_CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
PLUGIN_CONFIG_FILE="${PLUGIN_CONFIG_DIR}/settings.cfg"
PLUGIN_STATE_DIR="${PLUGIN_CONFIG_DIR}/state"
RUN_ACTIVE_FILE="${PLUGIN_STATE_DIR}/run_active.state"
LAST_ACTION_FILE="${PLUGIN_STATE_DIR}/last_action.state"
NOTIFY_SCRIPT="/usr/local/emhttp/webGui/scripts/notify"

DEFAULT_BLACK_LIST=("Example1" "Example2")
BLACK_LIST=("${DEFAULT_BLACK_LIST[@]}")
DEFAULT_AUTO_EXECUTE_ON_STARTUP=0
AUTO_EXECUTE_ON_STARTUP=$DEFAULT_AUTO_EXECUTE_ON_STARTUP
DEFAULT_OPERATION_MODE="automatic"
OPERATION_MODE="$DEFAULT_OPERATION_MODE"
DEFAULT_MAX_ASPM_LEVEL=3
MAX_ASPM_LEVEL=$DEFAULT_MAX_ASPM_LEVEL
DEFAULT_ENABLE_ASPM_OPTIMIZATION=1
ENABLE_ASPM_OPTIMIZATION=$DEFAULT_ENABLE_ASPM_OPTIMIZATION
DEFAULT_ENABLE_CLKPM_OPTIMIZATION=1
ENABLE_CLKPM_OPTIMIZATION=$DEFAULT_ENABLE_CLKPM_OPTIMIZATION
DEFAULT_ENABLE_LTR_OPTIMIZATION=1
ENABLE_LTR_OPTIMIZATION=$DEFAULT_ENABLE_LTR_OPTIMIZATION
DEFAULT_ENABLE_L1SS_OPTIMIZATION=0
ENABLE_L1SS_OPTIMIZATION=$DEFAULT_ENABLE_L1SS_OPTIMIZATION
DEFAULT_ENABLE_PCI_RUNTIME_PM_OPTIMIZATION=0
ENABLE_PCI_RUNTIME_PM_OPTIMIZATION=$DEFAULT_ENABLE_PCI_RUNTIME_PM_OPTIMIZATION
DEFAULT_FORCE_ASPM_MODE=0
FORCE_ASPM_MODE=$DEFAULT_FORCE_ASPM_MODE
DEFAULT_FORCE_ASPM_ENDPOINT_MODE=0
FORCE_ASPM_ENDPOINT_MODE=$DEFAULT_FORCE_ASPM_ENDPOINT_MODE
DEFAULT_FORCE_ASPM_BRIDGE_MODE=0
FORCE_ASPM_BRIDGE_MODE=$DEFAULT_FORCE_ASPM_BRIDGE_MODE
DEFAULT_FORCE_ASPM=0
FORCE_ASPM=$DEFAULT_FORCE_ASPM
DEFAULT_MANUAL_TARGET_ASPM_MODE=3
MANUAL_TARGET_ASPM_MODE=$DEFAULT_MANUAL_TARGET_ASPM_MODE
DEFAULT_MANUAL_INCLUDE_ENDPOINTS=1
MANUAL_INCLUDE_ENDPOINTS=$DEFAULT_MANUAL_INCLUDE_ENDPOINTS
DEFAULT_MANUAL_INCLUDE_BRIDGES=1
MANUAL_INCLUDE_BRIDGES=$DEFAULT_MANUAL_INCLUDE_BRIDGES
MANUAL_SELECTED_DEVICES=()

RUN_CONTEXT=""
RUN_ACTIVE=0
RUN_COMPLETED=0
RUN_START_EPOCH=0

# Runtime feature toggles (loaded from config)
ENABLE_ASPM=1
ENABLE_CLKPM=1
ENABLE_LTR=1
ENABLE_L1SS=0
ENABLE_PCI_RUNTIME_PM=0
PRINT_PATH_DIAG=1

current_epoch() {
    date +%s
}

timestamp_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sanitize_single_line() {
    local value=$1

    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    echo "$value"
}

trim_whitespace() {
    local value=$1

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    echo "$value"
}

default_blacklist_csv() {
    local IFS=,
    echo "${DEFAULT_BLACK_LIST[*]}"
}

bool_from_string() {
    case "${1,,}" in
        1|true|yes|on|enabled) echo 1 ;;
        *) echo 0 ;;
    esac
}

aspm_mode_from_string() {
    local fallback=${2:-$DEFAULT_MANUAL_TARGET_ASPM_MODE}

    case "${1,,}" in
        0|disabled|off) echo 0 ;;
        1|l0|l0s) echo 1 ;;
        2|l1) echo 2 ;;
        3|l0s+l1|both|auto) echo 3 ;;
        *) echo "$fallback" ;;
    esac
}

force_aspm_mode_from_string() {
    local fallback=${2:-$DEFAULT_FORCE_ASPM_MODE}

    case "${1,,}" in
        0|disabled|off) echo 0 ;;
        1|l0|l0s) echo 1 ;;
        2|l1) echo 2 ;;
        3|l0s+l1|both|auto) echo 3 ;;
        4|manual-only|manual_only|manualonly|manual) echo 4 ;;
        *) echo "$fallback" ;;
    esac
}

clamp_aspm_mode_by_max() {
    local target=$1

    case "$MAX_ASPM_LEVEL" in
        1)
            [[ $(( target & 1 )) -eq 1 ]] && echo 1 || echo 0
            ;;
        2)
            [[ $(( target & 2 )) -eq 2 ]] && echo 2 || echo 0
            ;;
        3|*)
            echo "$target"
            ;;
    esac
}

csv_to_array() {
    local csv=$1
    local item

    MANUAL_SELECTED_DEVICES=()
    IFS=',' read -r -a _parsed_devices <<< "$csv"
    for item in "${_parsed_devices[@]}"; do
        item=$(trim_whitespace "$item")
        [[ -n "$item" ]] && MANUAL_SELECTED_DEVICES+=("$item")
    done
}

array_contains() {
    local needle=$1
    shift
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

is_manual_selected_device() {
    local dev=$1
    local short_dev=${dev#0000:}

    array_contains "$dev" "${MANUAL_SELECTED_DEVICES[@]}" && return 0
    array_contains "$short_dev" "${MANUAL_SELECTED_DEVICES[@]}" && return 0
    return 1
}

device_scope() {
    local full_desc=$1

    if [[ "$full_desc" =~ PCI\ bridge|Root\ Port ]]; then
        echo "bridge"
    else
        echo "endpoint"
    fi
}

read_config_value() {
    local key=$1
    local default_value=$2
    local raw_line raw_value

    [[ -r "$PLUGIN_CONFIG_FILE" ]] || {
        echo "$default_value"
        return 0
    }

    raw_line=$(grep -E "^${key}=" "$PLUGIN_CONFIG_FILE" | tail -n 1)
    if [[ -z "$raw_line" ]]; then
        echo "$default_value"
        return 0
    fi

    raw_value=${raw_line#${key}=}
    raw_value=${raw_value%\"}
    raw_value=${raw_value#\"}
    echo "$raw_value"
}

ensure_config_file() {
    mkdir -p "$PLUGIN_CONFIG_DIR" || return 1

    if [[ ! -f "$PLUGIN_CONFIG_FILE" ]]; then
        {
            printf 'BLACK_LIST="%s"\n' "$(default_blacklist_csv)"
            printf 'AUTO_EXECUTE_ON_STARTUP="%s"\n' "$DEFAULT_AUTO_EXECUTE_ON_STARTUP"
            printf 'OPERATION_MODE="%s"\n' "$DEFAULT_OPERATION_MODE"
            printf 'MAX_ASPM_LEVEL="%s"\n' "$DEFAULT_MAX_ASPM_LEVEL"
            printf 'ENABLE_ASPM_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_ASPM_OPTIMIZATION"
            printf 'ENABLE_CLKPM_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_CLKPM_OPTIMIZATION"
            printf 'ENABLE_LTR_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_LTR_OPTIMIZATION"
            printf 'ENABLE_L1SS_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_L1SS_OPTIMIZATION"
            printf 'ENABLE_PCI_RUNTIME_PM_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_PCI_RUNTIME_PM_OPTIMIZATION"
            printf 'FORCE_ASPM_MODE="%s"\n' "$DEFAULT_FORCE_ASPM_MODE"
            printf 'FORCE_ASPM_ENDPOINT_MODE="%s"\n' "$DEFAULT_FORCE_ASPM_ENDPOINT_MODE"
            printf 'FORCE_ASPM_BRIDGE_MODE="%s"\n' "$DEFAULT_FORCE_ASPM_BRIDGE_MODE"
            printf 'FORCE_ASPM="%s"\n' "$DEFAULT_FORCE_ASPM"
            printf 'MANUAL_FORCE_ASPM="%s"\n' "$DEFAULT_FORCE_ASPM"
            printf 'MANUAL_TARGET_ASPM_MODE="%s"\n' "$DEFAULT_MANUAL_TARGET_ASPM_MODE"
            printf 'MANUAL_INCLUDE_ENDPOINTS="%s"\n' "$DEFAULT_MANUAL_INCLUDE_ENDPOINTS"
            printf 'MANUAL_INCLUDE_BRIDGES="%s"\n' "$DEFAULT_MANUAL_INCLUDE_BRIDGES"
            printf 'MANUAL_SELECTED_DEVICES=""\n'
        } > "$PLUGIN_CONFIG_FILE" || return 1
    else
        grep -q '^BLACK_LIST=' "$PLUGIN_CONFIG_FILE" || printf 'BLACK_LIST="%s"\n' "$(default_blacklist_csv)" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^AUTO_EXECUTE_ON_STARTUP=' "$PLUGIN_CONFIG_FILE" || printf 'AUTO_EXECUTE_ON_STARTUP="%s"\n' "$DEFAULT_AUTO_EXECUTE_ON_STARTUP" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^OPERATION_MODE=' "$PLUGIN_CONFIG_FILE" || printf 'OPERATION_MODE="%s"\n' "$DEFAULT_OPERATION_MODE" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^MAX_ASPM_LEVEL=' "$PLUGIN_CONFIG_FILE" || printf 'MAX_ASPM_LEVEL="%s"\n' "$DEFAULT_MAX_ASPM_LEVEL" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^ENABLE_ASPM_OPTIMIZATION=' "$PLUGIN_CONFIG_FILE" || printf 'ENABLE_ASPM_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_ASPM_OPTIMIZATION" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^ENABLE_CLKPM_OPTIMIZATION=' "$PLUGIN_CONFIG_FILE" || printf 'ENABLE_CLKPM_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_CLKPM_OPTIMIZATION" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^ENABLE_LTR_OPTIMIZATION=' "$PLUGIN_CONFIG_FILE" || printf 'ENABLE_LTR_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_LTR_OPTIMIZATION" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^ENABLE_L1SS_OPTIMIZATION=' "$PLUGIN_CONFIG_FILE" || printf 'ENABLE_L1SS_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_L1SS_OPTIMIZATION" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^ENABLE_PCI_RUNTIME_PM_OPTIMIZATION=' "$PLUGIN_CONFIG_FILE" || printf 'ENABLE_PCI_RUNTIME_PM_OPTIMIZATION="%s"\n' "$DEFAULT_ENABLE_PCI_RUNTIME_PM_OPTIMIZATION" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^FORCE_ASPM_MODE=' "$PLUGIN_CONFIG_FILE" || printf 'FORCE_ASPM_MODE="%s"\n' "$DEFAULT_FORCE_ASPM_MODE" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^FORCE_ASPM_ENDPOINT_MODE=' "$PLUGIN_CONFIG_FILE" || printf 'FORCE_ASPM_ENDPOINT_MODE="%s"\n' "$DEFAULT_FORCE_ASPM_ENDPOINT_MODE" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^FORCE_ASPM_BRIDGE_MODE=' "$PLUGIN_CONFIG_FILE" || printf 'FORCE_ASPM_BRIDGE_MODE="%s"\n' "$DEFAULT_FORCE_ASPM_BRIDGE_MODE" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^FORCE_ASPM=' "$PLUGIN_CONFIG_FILE" || printf 'FORCE_ASPM="%s"\n' "$DEFAULT_FORCE_ASPM" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^MANUAL_FORCE_ASPM=' "$PLUGIN_CONFIG_FILE" || printf 'MANUAL_FORCE_ASPM="%s"\n' "$DEFAULT_FORCE_ASPM" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^MANUAL_TARGET_ASPM_MODE=' "$PLUGIN_CONFIG_FILE" || printf 'MANUAL_TARGET_ASPM_MODE="%s"\n' "$DEFAULT_MANUAL_TARGET_ASPM_MODE" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^MANUAL_INCLUDE_ENDPOINTS=' "$PLUGIN_CONFIG_FILE" || printf 'MANUAL_INCLUDE_ENDPOINTS="%s"\n' "$DEFAULT_MANUAL_INCLUDE_ENDPOINTS" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^MANUAL_INCLUDE_BRIDGES=' "$PLUGIN_CONFIG_FILE" || printf 'MANUAL_INCLUDE_BRIDGES="%s"\n' "$DEFAULT_MANUAL_INCLUDE_BRIDGES" >> "$PLUGIN_CONFIG_FILE"
        grep -q '^MANUAL_SELECTED_DEVICES=' "$PLUGIN_CONFIG_FILE" || printf 'MANUAL_SELECTED_DEVICES=""\n' >> "$PLUGIN_CONFIG_FILE"
    fi

    return 0
}

load_settings_from_config() {
    local raw_line raw_value
    local parsed entry raw_auto raw_mode raw_force raw_force_mode raw_target
    local raw_force_endpoint_mode raw_force_bridge_mode
    local raw_max_aspm raw_enable_aspm raw_enable_clkpm raw_enable_ltr raw_enable_l1ss
    local raw_enable_pci_runtime_pm
    local raw_manual_endpoints raw_manual_bridges raw_manual_devices

    BLACK_LIST=("${DEFAULT_BLACK_LIST[@]}")

    [[ -r "$PLUGIN_CONFIG_FILE" ]] || return 0

    raw_line=$(grep -E '^BLACK_LIST=' "$PLUGIN_CONFIG_FILE" | tail -n 1)
    [[ -n "$raw_line" ]] || return 0

    raw_value=${raw_line#BLACK_LIST=}
    raw_value=${raw_value%\"}
    raw_value=${raw_value#\"}

    IFS=',' read -r -a parsed <<< "$raw_value"
    BLACK_LIST=()
    for entry in "${parsed[@]}"; do
        entry=$(trim_whitespace "$entry")
        [[ -n "$entry" ]] && BLACK_LIST+=("$entry")
    done

    [[ "${#BLACK_LIST[@]}" -eq 0 ]] && BLACK_LIST=("${DEFAULT_BLACK_LIST[@]}")

    raw_auto=$(read_config_value "AUTO_EXECUTE_ON_STARTUP" "$DEFAULT_AUTO_EXECUTE_ON_STARTUP")
    AUTO_EXECUTE_ON_STARTUP=$(bool_from_string "$raw_auto")

    raw_mode=$(read_config_value "OPERATION_MODE" "$DEFAULT_OPERATION_MODE")
    case "${raw_mode,,}" in
        manual) OPERATION_MODE="manual" ;;
        *) OPERATION_MODE="automatic" ;;
    esac

    raw_max_aspm=$(read_config_value "MAX_ASPM_LEVEL" "$DEFAULT_MAX_ASPM_LEVEL")
    MAX_ASPM_LEVEL=$(aspm_mode_from_string "$raw_max_aspm")

    raw_enable_aspm=$(read_config_value "ENABLE_ASPM_OPTIMIZATION" "$DEFAULT_ENABLE_ASPM_OPTIMIZATION")
    ENABLE_ASPM_OPTIMIZATION=$(bool_from_string "$raw_enable_aspm")

    raw_enable_clkpm=$(read_config_value "ENABLE_CLKPM_OPTIMIZATION" "$DEFAULT_ENABLE_CLKPM_OPTIMIZATION")
    ENABLE_CLKPM_OPTIMIZATION=$(bool_from_string "$raw_enable_clkpm")

    raw_enable_ltr=$(read_config_value "ENABLE_LTR_OPTIMIZATION" "$DEFAULT_ENABLE_LTR_OPTIMIZATION")
    ENABLE_LTR_OPTIMIZATION=$(bool_from_string "$raw_enable_ltr")

    raw_enable_l1ss=$(read_config_value "ENABLE_L1SS_OPTIMIZATION" "$DEFAULT_ENABLE_L1SS_OPTIMIZATION")
    ENABLE_L1SS_OPTIMIZATION=$(bool_from_string "$raw_enable_l1ss")

    raw_enable_pci_runtime_pm=$(read_config_value "ENABLE_PCI_RUNTIME_PM_OPTIMIZATION" "$DEFAULT_ENABLE_PCI_RUNTIME_PM_OPTIMIZATION")
    ENABLE_PCI_RUNTIME_PM_OPTIMIZATION=$(bool_from_string "$raw_enable_pci_runtime_pm")

    raw_force=$(read_config_value "FORCE_ASPM" "$(read_config_value "MANUAL_FORCE_ASPM" "$DEFAULT_FORCE_ASPM")")
    raw_target=$(read_config_value "MANUAL_TARGET_ASPM_MODE" "$DEFAULT_MANUAL_TARGET_ASPM_MODE")
    raw_force_mode=$(read_config_value "FORCE_ASPM_MODE" "$(if [[ "$(bool_from_string "$raw_force")" -eq 1 ]]; then echo "$raw_target"; else echo "$DEFAULT_FORCE_ASPM_MODE"; fi)")
    raw_force_endpoint_mode=$(read_config_value "FORCE_ASPM_ENDPOINT_MODE" "$raw_force_mode")
    raw_force_bridge_mode=$(read_config_value "FORCE_ASPM_BRIDGE_MODE" "$raw_force_mode")

    FORCE_ASPM_MODE=$(force_aspm_mode_from_string "$raw_force_mode" "$DEFAULT_FORCE_ASPM_MODE")
    FORCE_ASPM_ENDPOINT_MODE=$(force_aspm_mode_from_string "$raw_force_endpoint_mode" "$FORCE_ASPM_MODE")
    FORCE_ASPM_BRIDGE_MODE=$(force_aspm_mode_from_string "$raw_force_bridge_mode" "$FORCE_ASPM_MODE")
    FORCE_ASPM=$([[ "$FORCE_ASPM_ENDPOINT_MODE" -eq 0 && "$FORCE_ASPM_BRIDGE_MODE" -eq 0 ]] && echo 0 || echo 1)

    MANUAL_TARGET_ASPM_MODE=$(aspm_mode_from_string "$raw_target" "$DEFAULT_MANUAL_TARGET_ASPM_MODE")

    raw_manual_endpoints=$(read_config_value "MANUAL_INCLUDE_ENDPOINTS" "$DEFAULT_MANUAL_INCLUDE_ENDPOINTS")
    MANUAL_INCLUDE_ENDPOINTS=$(bool_from_string "$raw_manual_endpoints")

    raw_manual_bridges=$(read_config_value "MANUAL_INCLUDE_BRIDGES" "$DEFAULT_MANUAL_INCLUDE_BRIDGES")
    MANUAL_INCLUDE_BRIDGES=$(bool_from_string "$raw_manual_bridges")

    raw_manual_devices=$(read_config_value "MANUAL_SELECTED_DEVICES" "")
    csv_to_array "$raw_manual_devices"
}

ensure_state_dir() {
    mkdir -p "$PLUGIN_STATE_DIR" || return 1
    return 0
}

get_state_value() {
    local file=$1
    local key=$2
    local line

    [[ -r "$file" ]] || return 1
    line=$(grep -E "^${key}=" "$file" | tail -n 1)
    [[ -n "$line" ]] || return 1
    echo "${line#${key}=}"
}

record_action() {
    local action_desc=$1
    local action_cmd=$2
    local now_epoch now_iso

    now_epoch=$(current_epoch)
    now_iso=$(timestamp_iso)
    action_desc=$(sanitize_single_line "$action_desc")
    action_cmd=$(sanitize_single_line "$action_cmd")

    ensure_state_dir || return 1
    {
        printf 'timestamp_epoch=%s\n' "$now_epoch"
        printf 'timestamp_iso=%s\n' "$now_iso"
        printf 'action_desc=%s\n' "$action_desc"
        printf 'action_cmd=%s\n' "$action_cmd"
    } > "$LAST_ACTION_FILE"
}

read_last_action_command() {
    get_state_value "$LAST_ACTION_FILE" "action_cmd" 2>/dev/null || echo "unknown"
}

read_last_action_desc() {
    get_state_value "$LAST_ACTION_FILE" "action_desc" 2>/dev/null || echo "unknown"
}

read_last_action_epoch() {
    get_state_value "$LAST_ACTION_FILE" "timestamp_epoch" 2>/dev/null || echo "0"
}

write_run_active_marker() {
    local context=$1

    ensure_state_dir || return 1
    {
        printf 'started_epoch=%s\n' "$RUN_START_EPOCH"
        printf 'started_iso=%s\n' "$(timestamp_iso)"
        printf 'context=%s\n' "$context"
        printf 'pid=%s\n' "$$"
    } > "$RUN_ACTIVE_FILE"
}

clear_run_active_marker() {
    rm -f "$RUN_ACTIVE_FILE"
}

disable_auto_execute_on_startup() {
    local temp_file

    ensure_config_file || return 1
    temp_file=$(mktemp) || return 1

    if ! awk '
        BEGIN { updated = 0 }
        /^AUTO_EXECUTE_ON_STARTUP=/ {
            print "AUTO_EXECUTE_ON_STARTUP=\"0\""
            updated = 1
            next
        }
        { print }
        END {
            if (updated == 0) {
                print "AUTO_EXECUTE_ON_STARTUP=\"0\""
            }
        }
    ' "$PLUGIN_CONFIG_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! mv "$temp_file" "$PLUGIN_CONFIG_FILE"; then
        rm -f "$temp_file"
        return 1
    fi

    AUTO_EXECUTE_ON_STARTUP=0
    return 0
}

send_unraid_notification() {
    local subject=$1
    local message=$2

    if [[ -x "$NOTIFY_SCRIPT" ]]; then
        "$NOTIFY_SCRIPT" -e "$PLUGIN_NAME" -i "alert" -s "$subject" -d "$message" >/dev/null 2>&1 || true
    fi
}

notify_crash_disabled() {
    local detail=$1
    local last_cmd=$2

    send_unraid_notification \
        "Unraid Power Optimizer: auto execution disabled" \
        "Auto execution was disabled for safety due to a suspected crash. Last recorded command: ${last_cmd}. ${detail}"
}

inspect_previous_run_for_crash() {
    local stale_started now_epoch elapsed action_epoch last_cmd detail disable_note

    [[ -f "$RUN_ACTIVE_FILE" ]] || return 0

    stale_started=$(get_state_value "$RUN_ACTIVE_FILE" "started_epoch" 2>/dev/null)
    [[ "$stale_started" =~ ^[0-9]+$ ]] || stale_started=0

    action_epoch=$(read_last_action_epoch)
    if [[ "$action_epoch" =~ ^[0-9]+$ ]] && (( action_epoch >= stale_started )); then
        elapsed=$(( action_epoch - stale_started ))
    else
        now_epoch=$(current_epoch)
        elapsed=$(( now_epoch - stale_started ))
    fi
    (( elapsed < 0 )) && elapsed=0

    last_cmd=$(read_last_action_command)
    if (( elapsed < 60 )); then
        detail="The interruption happened within 60 seconds of execution start, so a likely cause could not be determined."
    else
        detail="The previous run appears to have crashed mid-execution."
    fi

    if disable_auto_execute_on_startup; then
        disable_note="AUTO_EXECUTE_ON_STARTUP was set to 0."
        echo "Crash protection: disabled startup auto execution after detecting an unfinished previous run."
    else
        disable_note="Failed to set AUTO_EXECUTE_ON_STARTUP to 0 in settings.cfg."
        echo "Crash protection warning: could not persist startup auto execution disable setting."
    fi

    detail="${detail} ${disable_note}"
    notify_crash_disabled "$detail" "$last_cmd"
    clear_run_active_marker
}

start_run_guard() {
    local context=$1

    RUN_CONTEXT=$context
    RUN_START_EPOCH=$(current_epoch)
    RUN_ACTIVE=1
    RUN_COMPLETED=0

    write_run_active_marker "$context" || return 1
    trap 'finalize_run_guard "$?"' EXIT INT TERM
}

finalize_run_guard() {
    local exit_code=$1
    local now_epoch elapsed last_cmd detail disable_note

    [[ "$RUN_ACTIVE" -eq 1 ]] || return 0

    if [[ "$RUN_COMPLETED" -eq 1 && "$exit_code" -eq 0 ]]; then
        clear_run_active_marker
        RUN_ACTIVE=0
        return 0
    fi

    now_epoch=$(current_epoch)
    elapsed=$(( now_epoch - RUN_START_EPOCH ))
    (( elapsed < 0 )) && elapsed=0

    last_cmd=$(read_last_action_command)
    if (( elapsed < 60 )); then
        detail="The interruption happened within 60 seconds of execution start, so a likely cause could not be determined."
    else
        detail="The optimizer process exited unexpectedly (exit code ${exit_code})."
    fi

    if disable_auto_execute_on_startup; then
        disable_note="AUTO_EXECUTE_ON_STARTUP was set to 0."
        echo "Crash protection: disabled startup auto execution after runtime interruption."
    else
        disable_note="Failed to set AUTO_EXECUTE_ON_STARTUP to 0 in settings.cfg."
        echo "Crash protection warning: could not persist startup auto execution disable setting."
    fi

    detail="${detail} ${disable_note}"
    notify_crash_disabled "$detail" "$last_cmd"
    clear_run_active_marker
    RUN_ACTIVE=0
}

require_dependencies() {
    command -v lspci >/dev/null 2>&1 || {
        echo "Error: lspci is required but not installed."
        return 1
    }
    command -v setpci >/dev/null 2>&1 || {
        echo "Error: setpci is required but not installed."
        return 1
    }
    return 0
}

show_usage() {
    echo "Usage: $0 [${PLUGIN_MODE_AUTO_OPTIMIZE}|${PLUGIN_MODE_STARTUP_AUTO_OPTIMIZE}]"
    echo
    echo "Modes:"
    echo "  ${PLUGIN_MODE_AUTO_OPTIMIZE}   Run configured PCIe power optimization"
    echo "  ${PLUGIN_MODE_STARTUP_AUTO_OPTIMIZE}   Internal startup mode (respects startup toggle/crash protection)"
}

resolve_target_mode_for_device() {
    local dev=$1
    local scope=${2:-endpoint}
    local mode_status
    local force_mode

    if [[ "$scope" == "bridge" ]]; then
        force_mode=$FORCE_ASPM_BRIDGE_MODE
    else
        force_mode=$FORCE_ASPM_ENDPOINT_MODE
    fi

    detect_link_power_capabilities "$dev"
    mode_status=$?

    if [[ "$mode_status" -eq 0 ]]; then
        ASPM_TARGET_MODE=$(clamp_aspm_mode_by_max "$ASPM_TARGET_MODE")
        return 0
    fi

    if [[ ( "$mode_status" -eq 2 || "$mode_status" -eq 3 ) && "$force_mode" -eq 4 ]]; then
        if [[ "$OPERATION_MODE" != "manual" ]]; then
            return "$mode_status"
        fi

        ASPM_TARGET_MODE=$MAX_ASPM_LEVEL
        CLKPM_SUPPORTED=0
        ASPM_TARGET_MODE=$(clamp_aspm_mode_by_max "$ASPM_TARGET_MODE")
        return 0
    fi

    if [[ "$force_mode" -ne 0 && ( "$mode_status" -eq 2 || "$mode_status" -eq 3 ) ]]; then
        ASPM_TARGET_MODE=$force_mode
        CLKPM_SUPPORTED=0
        ASPM_TARGET_MODE=$(clamp_aspm_mode_by_max "$ASPM_TARGET_MODE")
        return 0
    fi

    return "$mode_status"
}

init_counters() {
    # Summary counters
    ep_changed=0
    ep_already=0
    ep_blacklisted=0
    ep_no_pcie_cap=0
    ep_unsupported=0
    ep_lnkctl_read_fail=0
    ep_write_not_stick=0
    ep_write_fail=0
    ep_verify_fail=0
    ep_unknown=0

    br_changed=0
    br_already=0
    br_blacklisted=0
    br_no_pcie_cap=0
    br_unsupported=0
    br_lnkctl_read_fail=0
    br_write_not_stick=0
    br_write_fail=0
    br_verify_fail=0
    br_unknown=0

    ep_clkpm_enabled=0
    ep_clkpm_supported_disabled=0
    ep_clkpm_unsupported=0
    ep_clkpm_unknown=0

    br_clkpm_enabled=0
    br_clkpm_supported_disabled=0
    br_clkpm_unsupported=0
    br_clkpm_unknown=0

    ep_ltr_enabled=0
    ep_ltr_supported_disabled=0
    ep_ltr_unsupported=0
    ep_ltr_unknown=0
    ep_ltr_changed=0
    ep_ltr_already=0
    ep_ltr_enable_fail=0

    br_ltr_enabled=0
    br_ltr_supported_disabled=0
    br_ltr_unsupported=0
    br_ltr_unknown=0
    br_ltr_changed=0
    br_ltr_already=0
    br_ltr_enable_fail=0

    ep_l1ss_enabled=0
    ep_l1ss_supported_disabled=0
    ep_l1ss_unsupported=0
    ep_l1ss_absent=0
    ep_l1ss_unknown=0
    ep_l1ss_changed=0
    ep_l1ss_already=0
    ep_l1ss_enable_fail=0

    br_l1ss_enabled=0
    br_l1ss_supported_disabled=0
    br_l1ss_unsupported=0
    br_l1ss_absent=0
    br_l1ss_unknown=0
    br_l1ss_changed=0
    br_l1ss_already=0
    br_l1ss_enable_fail=0
}

is_blacklisted() {
    local full_desc=$1
    local bl

    for bl in "${BLACK_LIST[@]}"; do
        [[ "$full_desc" =~ $bl ]] && return 0
    done
    return 1
}

read_link_caps_dword() {
    local dev=$1
    local val

    # CAP_EXP resolves to the PCIe capability base.
    val=$(setpci -s "$dev" CAP_EXP+0c.l 2>/dev/null)
    val=${val//[[:space:]]/}
    [[ "$val" =~ ^[0-9a-fA-F]{8}$ ]] || return 1
    echo "$val"
}

read_link_ctl_word() {
    local dev=$1
    local val

    val=$(setpci -s "$dev" CAP_EXP+10.w 2>/dev/null)
    val=${val//[[:space:]]/}
    [[ "$val" =~ ^[0-9a-fA-F]{4}$ ]] || return 1
    echo "$val"
}

read_dev_cap2_dword() {
    local dev=$1
    local val

    val=$(setpci -s "$dev" CAP_EXP+24.l 2>/dev/null)
    val=${val//[[:space:]]/}
    [[ "$val" =~ ^[0-9a-fA-F]{8}$ ]] || return 1
    echo "$val"
}

read_dev_ctl2_word() {
    local dev=$1
    local val

    val=$(setpci -s "$dev" CAP_EXP+28.w 2>/dev/null)
    val=${val//[[:space:]]/}
    [[ "$val" =~ ^[0-9a-fA-F]{4}$ ]] || return 1
    echo "$val"
}

find_ext_cap() {
    local dev=$1
    local wanted_id=$2
    local pos=256
    local hdr id next

    while (( pos >= 256 && pos < 4096 )); do
        hdr=$(setpci -s "$dev" "$(printf "%x" "$pos").l" 2>/dev/null)
        hdr=${hdr//[[:space:]]/}
        [[ "$hdr" =~ ^[0-9a-fA-F]{8}$ ]] || return 1

        id=$((0x$hdr & 0xffff))
        next=$(((0x$hdr >> 20) & 0xfff))

        if (( id == wanted_id )); then
            printf "%x" "$pos"
            return 0
        fi

        (( next == 0 || next == pos )) && break
        pos=$next
    done

    return 1
}

# Populates ASPM_TARGET_MODE and CLKPM_SUPPORTED.
detect_link_power_capabilities() {
    local dev=$1
    local cap_dword

    cap_dword=$(read_link_caps_dword "$dev") || {
        ASPM_TARGET_MODE=0
        CLKPM_SUPPORTED=0
        return 2
    }

    # Bits 11:10 indicate ASPM support (00 none, 01 L0s, 10 L1, 11 both).
    ASPM_TARGET_MODE=$(( (0x$cap_dword >> 10) & 3 ))
    # Bit 18 indicates Clock Power Management support.
    CLKPM_SUPPORTED=$(( (0x$cap_dword >> 18) & 1 ))

    [[ "$ASPM_TARGET_MODE" -eq 0 ]] && return 3
    return 0
}

apply_link_power_settings() {
    local dev=$1
    local target_mode=$2
    local clkpm_supported=$3
    local current after mask value

    current=$(read_link_ctl_word "$dev") || return 1

    mask=0
    value=0

    if [[ "$ENABLE_ASPM" -eq 1 ]]; then
        mask=$((mask | 0x3))
        value=$((value | (target_mode & 0x3)))
    fi

    if [[ "$ENABLE_CLKPM" -eq 1 && "$clkpm_supported" -eq 1 ]]; then
        mask=$((mask | 0x100))
        value=$((value | 0x100))
    fi

    [[ "$mask" -eq 0 ]] && return 2

    [[ "$(( 0x$current & mask ))" -eq "$value" ]] && return 2

    record_action "Apply ASPM/CLKPM bits on ${dev}" "setpci -s ${dev} CAP_EXP+10.w=$(printf "%x" "$value"):$(printf "%x" "$mask")"
    setpci -s "$dev" CAP_EXP+10.w="$(printf "%x" "$value"):$(printf "%x" "$mask")" || return 4

    after=$(read_link_ctl_word "$dev") || return 5
    [[ "$(( 0x$after & mask ))" -eq "$value" ]] || return 3

    return 0
}

aspm_mode_label() {
    case "$1" in
        0) echo "disabled" ;;
        1) echo "L0" ;;
        2) echo "L1" ;;
        3) echo "L0+L1" ;;
        4) echo "manual-only" ;;
        *) echo "unknown" ;;
    esac
}

power_target_label() {
    local mode=$1
    local clkpm_supported=$2

    if [[ "$ENABLE_ASPM" -eq 0 && "$ENABLE_CLKPM" -eq 1 && "$clkpm_supported" -eq 1 ]]; then
        echo "CLKPM-only"
    elif [[ "$ENABLE_ASPM" -eq 0 ]]; then
        echo "ASPM-disabled"
    elif [[ "$ENABLE_CLKPM" -eq 1 && "$clkpm_supported" -eq 1 ]]; then
        echo "$(aspm_mode_label "$mode")+CLKPM"
    else
        echo "$(aspm_mode_label "$mode")"
    fi
}

get_ltr_state() {
    local dev=$1
    local cap2 ctl2 ltr_supported ltr_enabled

    cap2=$(read_dev_cap2_dword "$dev") || {
        echo "unknown"
        return 0
    }

    ltr_supported=$(( (0x$cap2 >> 11) & 1 ))
    if [[ "$ltr_supported" -eq 0 ]]; then
        echo "unsupported"
        return 0
    fi

    ctl2=$(read_dev_ctl2_word "$dev") || {
        echo "unknown"
        return 0
    }

    ltr_enabled=$(( (0x$ctl2 >> 10) & 1 ))
    if [[ "$ltr_enabled" -eq 1 ]]; then
        echo "enabled"
    else
        echo "supported-disabled"
    fi
}

# Returns: 0 changed, 1 unreadable, 2 unsupported, 3 already enabled,
# 4 write failed, 5 verify read failed, 6 write did not stick.
ensure_ltr_enabled() {
    local dev=$1
    local cap2 ctl2 after ltr_supported

    cap2=$(read_dev_cap2_dword "$dev") || return 1
    ltr_supported=$(( (0x$cap2 >> 11) & 1 ))
    [[ "$ltr_supported" -eq 1 ]] || return 2

    ctl2=$(read_dev_ctl2_word "$dev") || return 1
    [[ "$(( (0x$ctl2 >> 10) & 1 ))" -eq 1 ]] && return 3

    record_action "Enable LTR bit on ${dev}" "setpci -s ${dev} CAP_EXP+28.w=400:400"
    setpci -s "$dev" CAP_EXP+28.w="400:400" || return 4

    after=$(read_dev_ctl2_word "$dev") || return 5
    [[ "$(( (0x$after >> 10) & 1 ))" -eq 1 ]] || return 6

    return 0
}

get_l1ss_state() {
    local dev=$1
    local off cap ctl support_mask enabled_mask

    off=$(find_ext_cap "$dev" $((0x1e))) || {
        echo "absent"
        return 0
    }

    cap=$(setpci -s "$dev" "$(printf "%x" $((0x$off + 4))).l" 2>/dev/null)
    ctl=$(setpci -s "$dev" "$(printf "%x" $((0x$off + 8))).l" 2>/dev/null)
    cap=${cap//[[:space:]]/}
    ctl=${ctl//[[:space:]]/}

    [[ "$cap" =~ ^[0-9a-fA-F]{8}$ && "$ctl" =~ ^[0-9a-fA-F]{8}$ ]] || {
        echo "unknown"
        return 0
    }

    support_mask=$((0x$cap & 0xf))
    enabled_mask=$((0x$ctl & 0xf))

    if [[ "$support_mask" -eq 0 ]]; then
        echo "unsupported"
    elif [[ "$enabled_mask" -eq 0 ]]; then
        echo "supported-disabled"
    else
        echo "enabled"
    fi
}

# Returns: 0 changed, 1 unreadable, 2 absent, 3 unsupported,
# 4 already enabled, 5 write failed, 6 verify read failed, 7 write did not stick.
ensure_l1ss_enabled() {
    local dev=$1
    local off cap ctl support_mask enabled_mask desired_mask ctl_off after

    off=$(find_ext_cap "$dev" $((0x1e))) || return 2

    cap=$(setpci -s "$dev" "$(printf "%x" $((0x$off + 4))).l" 2>/dev/null)
    ctl=$(setpci -s "$dev" "$(printf "%x" $((0x$off + 8))).l" 2>/dev/null)
    cap=${cap//[[:space:]]/}
    ctl=${ctl//[[:space:]]/}

    [[ "$cap" =~ ^[0-9a-fA-F]{8}$ && "$ctl" =~ ^[0-9a-fA-F]{8}$ ]] || return 1

    support_mask=$((0x$cap & 0xf))
    [[ "$support_mask" -ne 0 ]] || return 3

    enabled_mask=$((0x$ctl & 0xf))
    desired_mask=$support_mask
    [[ "$enabled_mask" -eq "$desired_mask" ]] && return 4

    ctl_off=$(printf "%x" $((0x$off + 8)))
    record_action "Enable L1SS bits on ${dev}" "setpci -s ${dev} ${ctl_off}.l=$(printf "%x" "$desired_mask"):f"
    setpci -s "$dev" "${ctl_off}.l=$(printf "%x" "$desired_mask"):f" || return 5

    after=$(setpci -s "$dev" "${ctl_off}.l" 2>/dev/null)
    after=${after//[[:space:]]/}
    [[ "$after" =~ ^[0-9a-fA-F]{8}$ ]] || return 6
    [[ "$((0x$after & 0xf))" -eq "$desired_mask" ]] || return 7

    return 0
}

apply_pci_runtime_pm_all() {
    local path
    local total_targets=0
    local writable_targets=0
    local skipped_not_writable=0
    local write_successes=0
    local write_failures=0

    echo "  PCI runtime PM target scope: all PCI devices (/sys/bus/pci/devices/*/power/control)"

    for path in /sys/bus/pci/devices/????:??:??.?/power/control; do
        if [[ ! -e "$path" ]]; then
            continue
        fi

        ((total_targets++))

        if [[ ! -w "$path" ]]; then
            ((skipped_not_writable++))
            echo "    Skip (not writable): ${path}"
            continue
        fi

        ((writable_targets++))

        record_action "Enable PCI runtime PM" "echo auto > ${path}"
        if echo auto > "$path" 2>/dev/null; then
            ((write_successes++))
            echo "    Set to auto: ${path}"
        else
            ((write_failures++))
            echo "    Failed to write auto to ${path}"
        fi
    done

    if [[ "$total_targets" -eq 0 ]]; then
        echo "    No PCI runtime PM control files found."
    fi

    echo "  PCI runtime PM summary (all): targets=${total_targets} writable=${writable_targets} skipped_not_writable=${skipped_not_writable} write_successes=${write_successes} write_failures=${write_failures}"
}

apply_pci_runtime_pm_manual_selected() {
    local dev path resolved_path
    local selected_total=0
    local resolved_targets=0
    local writable_targets=0
    local skipped_missing=0
    local skipped_not_writable=0
    local write_successes=0
    local write_failures=0

    echo "  PCI runtime PM target scope: manually selected devices"

    for dev in "${MANUAL_SELECTED_DEVICES[@]}"; do
        ((selected_total++))

        path="/sys/bus/pci/devices/${dev}/power/control"
        resolved_path="$path"
        if [[ ! -e "$resolved_path" ]]; then
            resolved_path="/sys/bus/pci/devices/0000:${dev}/power/control"
        fi

        if [[ ! -e "$resolved_path" ]]; then
            ((skipped_missing++))
            echo "    Skip ${dev}: no PCI runtime PM control file found"
            continue
        fi

        ((resolved_targets++))

        if [[ ! -w "$resolved_path" ]]; then
            ((skipped_not_writable++))
            echo "    Skip ${dev}: not writable (${resolved_path})"
            continue
        fi

        ((writable_targets++))

        record_action "Enable PCI runtime PM for selected device ${dev}" "echo auto > ${resolved_path}"
        if echo auto > "$resolved_path" 2>/dev/null; then
            ((write_successes++))
            echo "    ${dev}: set to auto (${resolved_path})"
        else
            ((write_failures++))
            echo "    Warning ${dev}: failed to write auto (${resolved_path})"
        fi
    done

    echo "  PCI runtime PM summary (manual): selected=${selected_total} resolved=${resolved_targets} writable=${writable_targets} missing=${skipped_missing} skipped_not_writable=${skipped_not_writable} write_successes=${write_successes} write_failures=${write_failures}"
}

record_path_diag() {
    local scope=$1
    local dev=$2
    local clkpm_supported=$3
    local clkpm_state ltr_state l1ss_state link_ctl

    if [[ "$clkpm_supported" -eq 1 ]]; then
        link_ctl=$(read_link_ctl_word "$dev")
        if [[ -z "$link_ctl" ]]; then
            clkpm_state="unknown"
        elif [[ "$(( (0x$link_ctl >> 8) & 1 ))" -eq 1 ]]; then
            clkpm_state="enabled"
        else
            clkpm_state="supported-disabled"
        fi
    else
        clkpm_state="unsupported"
    fi

    ltr_state=$(get_ltr_state "$dev")
    l1ss_state=$(get_l1ss_state "$dev")

    if [[ "$scope" == "endpoint" ]]; then
        case "$clkpm_state" in
            enabled) ((ep_clkpm_enabled++)) ;;
            supported-disabled) ((ep_clkpm_supported_disabled++)) ;;
            unsupported) ((ep_clkpm_unsupported++)) ;;
            *) ((ep_clkpm_unknown++)) ;;
        esac
        case "$ltr_state" in
            enabled) ((ep_ltr_enabled++)) ;;
            supported-disabled) ((ep_ltr_supported_disabled++)) ;;
            unsupported) ((ep_ltr_unsupported++)) ;;
            *) ((ep_ltr_unknown++)) ;;
        esac
        case "$l1ss_state" in
            enabled) ((ep_l1ss_enabled++)) ;;
            supported-disabled) ((ep_l1ss_supported_disabled++)) ;;
            unsupported) ((ep_l1ss_unsupported++)) ;;
            absent) ((ep_l1ss_absent++)) ;;
            *) ((ep_l1ss_unknown++)) ;;
        esac
    else
        case "$clkpm_state" in
            enabled) ((br_clkpm_enabled++)) ;;
            supported-disabled) ((br_clkpm_supported_disabled++)) ;;
            unsupported) ((br_clkpm_unsupported++)) ;;
            *) ((br_clkpm_unknown++)) ;;
        esac
        case "$ltr_state" in
            enabled) ((br_ltr_enabled++)) ;;
            supported-disabled) ((br_ltr_supported_disabled++)) ;;
            unsupported) ((br_ltr_unsupported++)) ;;
            *) ((br_ltr_unknown++)) ;;
        esac
        case "$l1ss_state" in
            enabled) ((br_l1ss_enabled++)) ;;
            supported-disabled) ((br_l1ss_supported_disabled++)) ;;
            unsupported) ((br_l1ss_unsupported++)) ;;
            absent) ((br_l1ss_absent++)) ;;
            *) ((br_l1ss_unknown++)) ;;
        esac
    fi

    if [[ "$PRINT_PATH_DIAG" -eq 1 ]]; then
        echo "    PathDiag: CLKPM=${clkpm_state} LTR=${ltr_state} L1SS=${l1ss_state}"
    fi
}

run_auto_optimize() {
    local run_context=$1
    local full_desc mode_status
    local startup_mode=0

    [[ "$run_context" == "$PLUGIN_MODE_STARTUP_AUTO_OPTIMIZE" ]] && startup_mode=1

    ensure_config_file || {
        echo "Error: unable to initialize plugin config at ${PLUGIN_CONFIG_FILE}"
        return 1
    }
    ensure_state_dir || {
        echo "Error: unable to initialize plugin state at ${PLUGIN_STATE_DIR}"
        return 1
    }

    load_settings_from_config
    inspect_previous_run_for_crash
    rm -f "${PLUGIN_STATE_DIR}/crash_lock.state" 2>/dev/null || true

    if [[ "$startup_mode" -eq 1 && "$AUTO_EXECUTE_ON_STARTUP" -ne 1 ]]; then
        echo "Startup auto execution is disabled by user setting."
        return 0
    fi

    ENABLE_ASPM=$ENABLE_ASPM_OPTIMIZATION
    ENABLE_CLKPM=$ENABLE_CLKPM_OPTIMIZATION
    ENABLE_LTR=$ENABLE_LTR_OPTIMIZATION
    ENABLE_L1SS=$ENABLE_L1SS_OPTIMIZATION
    ENABLE_PCI_RUNTIME_PM=$ENABLE_PCI_RUNTIME_PM_OPTIMIZATION

    if [[ "$OPERATION_MODE" == "manual" && "${#MANUAL_SELECTED_DEVICES[@]}" -eq 0 ]]; then
        echo "Manual mode is selected, but no PCI devices were selected."
        return 0
    fi

    if [[ "$OPERATION_MODE" == "manual" && "$MANUAL_INCLUDE_ENDPOINTS" -eq 0 && "$MANUAL_INCLUDE_BRIDGES" -eq 0 ]]; then
        echo "Manual mode is selected, but both endpoint and bridge execution are disabled."
        return 0
    fi

    require_dependencies || return 1
    init_counters
    start_run_guard "$run_context" || {
        echo "Error: unable to start crash guard runtime tracking."
        return 1
    }

    record_action "Begin Auto Optimize run" "run_auto_optimize ${run_context}"

    echo "Starting Dependency-Aware ASPM Optimizer (${run_context})..."
    echo "Using config: ${PLUGIN_CONFIG_FILE}"
    echo "Operation Mode: ${OPERATION_MODE}"
    echo "Auto Execute on Startup: ${AUTO_EXECUTE_ON_STARTUP}"
    echo "Optimization Toggles: aspm=${ENABLE_ASPM} clkpm=${ENABLE_CLKPM} ltr=${ENABLE_LTR} l1ss=${ENABLE_L1SS} pci_runtime_pm=${ENABLE_PCI_RUNTIME_PM} max_aspm=$(aspm_mode_label "$MAX_ASPM_LEVEL")"
    echo "Force ASPM mode on unsupported endpoints: $(aspm_mode_label "$FORCE_ASPM_ENDPOINT_MODE")"
    echo "Force ASPM mode on unsupported bridges: $(aspm_mode_label "$FORCE_ASPM_BRIDGE_MODE")"
    if [[ "$OPERATION_MODE" == "manual" ]]; then
        echo "Manual Settings: include_endpoints=${MANUAL_INCLUDE_ENDPOINTS} include_bridges=${MANUAL_INCLUDE_BRIDGES} selected_devices=${#MANUAL_SELECTED_DEVICES[@]}"
    fi

    # --- PASS 1: ENDPOINTS (Bottom-Up) ---
    echo "Pass 1: Preparing Endpoints..."
    for dev in $(lspci -D | grep -vE "PCI bridge|Root Port" | awk '{print $1}'); do
        full_desc=$(lspci -D -s "$dev")

        if [[ "$OPERATION_MODE" == "manual" ]]; then
            [[ "$MANUAL_INCLUDE_ENDPOINTS" -eq 1 ]] || continue
            is_manual_selected_device "$dev" || continue
        else
            if is_blacklisted "$full_desc"; then
                ((ep_blacklisted++))
                echo "  Skipping blacklisted endpoint: $full_desc"
                continue
            fi
        fi

        record_action "Inspect endpoint ${dev}" "detect_link_power_capabilities ${dev}"

        resolve_target_mode_for_device "$dev" "endpoint"
        mode_status=$?
        case "$mode_status" in
            2)
                ((ep_no_pcie_cap++))
                echo "  Skipping endpoint (no readable capability): $full_desc"
                continue
                ;;
            3)
                if [[ "$ENABLE_ASPM" -eq 1 ]]; then
                    ((ep_unsupported++))
                    echo "  Skipping endpoint (ASPM unsupported): $full_desc"
                    continue
                fi
                ;;
            0)
                ;;
            *)
                ((ep_unknown++))
                echo "  Skipping endpoint (unknown capability read status ${mode_status}): $full_desc"
                continue
                ;;
        esac

        if [[ "$ENABLE_LTR" -eq 1 ]]; then
            record_action "Evaluate LTR setting for endpoint ${dev}" "ensure_ltr_enabled ${dev}"
            ensure_ltr_enabled "$dev"
            case $? in
                0)
                    ((ep_ltr_changed++))
                    echo "  Enabled LTR on endpoint: $full_desc"
                    ;;
                1)
                    ((ep_ltr_enable_fail++))
                    echo "  Warning: Could not read LTR control path on endpoint $full_desc"
                    ;;
                2)
                    ;;
                3)
                    ((ep_ltr_already++))
                    ;;
                *)
                    ((ep_ltr_enable_fail++))
                    echo "  Warning: LTR enable did not stick on endpoint $full_desc"
                    ;;
            esac
        fi

        record_action "Apply link power settings for endpoint ${dev}" "apply_link_power_settings ${dev} ${ASPM_TARGET_MODE} ${CLKPM_SUPPORTED}"
        if [[ "$ENABLE_ASPM" -eq 1 || "$ENABLE_CLKPM" -eq 1 ]]; then
            apply_link_power_settings "$dev" "$ASPM_TARGET_MODE" "$CLKPM_SUPPORTED"
            case $? in
                0)
                    ((ep_changed++))
                    echo "  Arming Endpoint: $full_desc ($(power_target_label "$ASPM_TARGET_MODE" "$CLKPM_SUPPORTED"))"
                    ;;
                1)
                    ((ep_lnkctl_read_fail++))
                    echo "  Skipping endpoint (unable to read Link Control): $full_desc"
                    ;;
                2)
                    ((ep_already++))
                    echo "  No change endpoint (already $(power_target_label "$ASPM_TARGET_MODE" "$CLKPM_SUPPORTED")): $full_desc"
                    ;;
                3)
                    ((ep_write_not_stick++))
                    echo "  Warning: ASPM/CLKPM write did not stick on endpoint $full_desc"
                    ;;
                4)
                    ((ep_write_fail++))
                    echo "  Warning: ASPM/CLKPM write command failed on endpoint $full_desc"
                    ;;
                5)
                    ((ep_verify_fail++))
                    echo "  Warning: Could not verify ASPM/CLKPM after write on endpoint $full_desc"
                    ;;
                *)
                    ((ep_unknown++))
                    echo "  Warning: Unknown ASPM/CLKPM apply status on endpoint $full_desc"
                    ;;
            esac
        fi

        if [[ "$ENABLE_L1SS" -eq 1 ]]; then
            record_action "Evaluate L1SS setting for endpoint ${dev}" "ensure_l1ss_enabled ${dev}"
            ensure_l1ss_enabled "$dev"
            case $? in
                0)
                    ((ep_l1ss_changed++))
                    echo "  Enabled L1SS on endpoint: $full_desc"
                    ;;
                1)
                    ((ep_l1ss_enable_fail++))
                    echo "  Warning: Could not read L1SS control path on endpoint $full_desc"
                    ;;
                2|3)
                    ;;
                4)
                    ((ep_l1ss_already++))
                    ;;
                *)
                    ((ep_l1ss_enable_fail++))
                    echo "  Warning: L1SS enable did not stick on endpoint $full_desc"
                    ;;
            esac
        fi

        record_path_diag "endpoint" "$dev" "$CLKPM_SUPPORTED"
    done

    # --- PASS 2: BRIDGES (Top-Down) ---
    echo "Pass 2: Enabling Bridges..."
    for dev in $(lspci -D | grep -E "PCI bridge|Root Port" | awk '{print $1}'); do
        full_desc=$(lspci -D -s "$dev")

        if [[ "$OPERATION_MODE" == "manual" ]]; then
            [[ "$MANUAL_INCLUDE_BRIDGES" -eq 1 ]] || continue
            is_manual_selected_device "$dev" || continue
        else
            if is_blacklisted "$full_desc"; then
                ((br_blacklisted++))
                echo "  Skipping blacklisted bridge: $full_desc"
                continue
            fi
        fi

        record_action "Inspect bridge ${dev}" "detect_link_power_capabilities ${dev}"

        resolve_target_mode_for_device "$dev" "bridge"
        mode_status=$?
        case "$mode_status" in
            2)
                ((br_no_pcie_cap++))
                echo "  Skipping bridge (no readable capability): $full_desc"
                continue
                ;;
            3)
                if [[ "$ENABLE_ASPM" -eq 1 ]]; then
                    ((br_unsupported++))
                    echo "  Skipping bridge (ASPM unsupported): $full_desc"
                    continue
                fi
                ;;
            0)
                ;;
            *)
                ((br_unknown++))
                echo "  Skipping bridge (unknown capability read status ${mode_status}): $full_desc"
                continue
                ;;
        esac

        if [[ "$ENABLE_LTR" -eq 1 ]]; then
            record_action "Evaluate LTR setting for bridge ${dev}" "ensure_ltr_enabled ${dev}"
            ensure_ltr_enabled "$dev"
            case $? in
                0)
                    ((br_ltr_changed++))
                    echo "  Enabled LTR on bridge: $full_desc"
                    ;;
                1)
                    ((br_ltr_enable_fail++))
                    echo "  Warning: Could not read LTR control path on bridge $full_desc"
                    ;;
                2)
                    ;;
                3)
                    ((br_ltr_already++))
                    ;;
                *)
                    ((br_ltr_enable_fail++))
                    echo "  Warning: LTR enable did not stick on bridge $full_desc"
                    ;;
            esac
        fi

        record_action "Apply link power settings for bridge ${dev}" "apply_link_power_settings ${dev} ${ASPM_TARGET_MODE} ${CLKPM_SUPPORTED}"
        if [[ "$ENABLE_ASPM" -eq 1 || "$ENABLE_CLKPM" -eq 1 ]]; then
            apply_link_power_settings "$dev" "$ASPM_TARGET_MODE" "$CLKPM_SUPPORTED"
            case $? in
                0)
                    ((br_changed++))
                    echo "  Opening Gate: $full_desc ($(power_target_label "$ASPM_TARGET_MODE" "$CLKPM_SUPPORTED"))"
                    ;;
                1)
                    ((br_lnkctl_read_fail++))
                    echo "  Skipping bridge (unable to read Link Control): $full_desc"
                    ;;
                2)
                    ((br_already++))
                    echo "  No change bridge (already $(power_target_label "$ASPM_TARGET_MODE" "$CLKPM_SUPPORTED")): $full_desc"
                    ;;
                3)
                    ((br_write_not_stick++))
                    echo "  Warning: ASPM/CLKPM write did not stick on bridge $full_desc"
                    ;;
                4)
                    ((br_write_fail++))
                    echo "  Warning: ASPM/CLKPM write command failed on bridge $full_desc"
                    ;;
                5)
                    ((br_verify_fail++))
                    echo "  Warning: Could not verify ASPM/CLKPM after write on bridge $full_desc"
                    ;;
                *)
                    ((br_unknown++))
                    echo "  Warning: Unknown ASPM/CLKPM apply status on bridge $full_desc"
                    ;;
            esac
        fi

        if [[ "$ENABLE_L1SS" -eq 1 ]]; then
            record_action "Evaluate L1SS setting for bridge ${dev}" "ensure_l1ss_enabled ${dev}"
            ensure_l1ss_enabled "$dev"
            case $? in
                0)
                    ((br_l1ss_changed++))
                    echo "  Enabled L1SS on bridge: $full_desc"
                    ;;
                1)
                    ((br_l1ss_enable_fail++))
                    echo "  Warning: Could not read L1SS control path on bridge $full_desc"
                    ;;
                2|3)
                    ;;
                4)
                    ((br_l1ss_already++))
                    ;;
                *)
                    ((br_l1ss_enable_fail++))
                    echo "  Warning: L1SS enable did not stick on bridge $full_desc"
                    ;;
            esac
        fi

        record_path_diag "bridge" "$dev" "$CLKPM_SUPPORTED"
    done

    if [[ "$ENABLE_PCI_RUNTIME_PM" -eq 1 ]]; then
        echo "Pass 3: Enabling PCI Runtime PM..."
        if [[ "$OPERATION_MODE" == "manual" ]]; then
            apply_pci_runtime_pm_manual_selected
        else
            apply_pci_runtime_pm_all
        fi
    fi

    ep_total=$((ep_changed + ep_already + ep_blacklisted + ep_no_pcie_cap + ep_unsupported + ep_lnkctl_read_fail + ep_write_not_stick + ep_write_fail + ep_verify_fail + ep_unknown))
    br_total=$((br_changed + br_already + br_blacklisted + br_no_pcie_cap + br_unsupported + br_lnkctl_read_fail + br_write_not_stick + br_write_fail + br_verify_fail + br_unknown))

    echo
    echo "--- ASPM Summary ---"
    echo "Endpoints: total=${ep_total} changed=${ep_changed} already=${ep_already} blacklisted=${ep_blacklisted} no_pcie_cap=${ep_no_pcie_cap} unsupported=${ep_unsupported} lnkctl_read_fail=${ep_lnkctl_read_fail} write_not_stick=${ep_write_not_stick} write_fail=${ep_write_fail} verify_fail=${ep_verify_fail} unknown=${ep_unknown}"
    echo "Bridges:   total=${br_total} changed=${br_changed} already=${br_already} blacklisted=${br_blacklisted} no_pcie_cap=${br_no_pcie_cap} unsupported=${br_unsupported} lnkctl_read_fail=${br_lnkctl_read_fail} write_not_stick=${br_write_not_stick} write_fail=${br_write_fail} verify_fail=${br_verify_fail} unknown=${br_unknown}"
    echo
    echo "--- Power Path Diagnostics ---"
    echo "Endpoints CLKPM: enabled=${ep_clkpm_enabled} supported_disabled=${ep_clkpm_supported_disabled} unsupported=${ep_clkpm_unsupported} unknown=${ep_clkpm_unknown}"
    echo "Endpoints LTR:   enabled=${ep_ltr_enabled} supported_disabled=${ep_ltr_supported_disabled} unsupported=${ep_ltr_unsupported} unknown=${ep_ltr_unknown}"
    echo "Endpoints LTR programming: changed=${ep_ltr_changed} already=${ep_ltr_already} failed=${ep_ltr_enable_fail}"
    echo "Endpoints L1SS:  enabled=${ep_l1ss_enabled} supported_disabled=${ep_l1ss_supported_disabled} unsupported=${ep_l1ss_unsupported} absent=${ep_l1ss_absent} unknown=${ep_l1ss_unknown}"
    echo "Endpoints L1SS programming: changed=${ep_l1ss_changed} already=${ep_l1ss_already} failed=${ep_l1ss_enable_fail}"
    echo "Bridges CLKPM:   enabled=${br_clkpm_enabled} supported_disabled=${br_clkpm_supported_disabled} unsupported=${br_clkpm_unsupported} unknown=${br_clkpm_unknown}"
    echo "Bridges LTR:     enabled=${br_ltr_enabled} supported_disabled=${br_ltr_supported_disabled} unsupported=${br_ltr_unsupported} unknown=${br_ltr_unknown}"
    echo "Bridges LTR programming:   changed=${br_ltr_changed} already=${br_ltr_already} failed=${br_ltr_enable_fail}"
    echo "Bridges L1SS:    enabled=${br_l1ss_enabled} supported_disabled=${br_l1ss_supported_disabled} unsupported=${br_l1ss_unsupported} absent=${br_l1ss_absent} unknown=${br_l1ss_unknown}"
    echo "Bridges L1SS programming: changed=${br_l1ss_changed} already=${br_l1ss_already} failed=${br_l1ss_enable_fail}"

    echo -e "\n--- Optimization Complete ---"
    RUN_COMPLETED=1
}

mode=${1:-$PLUGIN_MODE_AUTO_OPTIMIZE}
case "$mode" in
    "$PLUGIN_MODE_AUTO_OPTIMIZE")
        run_auto_optimize "$PLUGIN_MODE_AUTO_OPTIMIZE"
        ;;
    "$PLUGIN_MODE_STARTUP_AUTO_OPTIMIZE")
        run_auto_optimize "$PLUGIN_MODE_STARTUP_AUTO_OPTIMIZE"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo "Unknown mode: $mode"
        show_usage
        exit 2
        ;;
esac
