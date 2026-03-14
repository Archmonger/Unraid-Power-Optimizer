#!/bin/bash

enable_timestamped_output() {
    exec > >(while IFS= read -r line; do
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done) 2>&1
}

enable_timestamped_output

PLUGIN_NAME="power.optimizer"
PLUGIN_CONFIG_FILE="/boot/config/plugins/${PLUGIN_NAME}/settings.cfg"

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

bool_from_string() {
    case "${1,,}" in
        1|true|yes|on|enabled) echo 1 ;;
        *) echo 0 ;;
    esac
}

runtime_target_from_string() {
    case "${1,,}" in
        disabled|off|on) echo "disabled" ;;
        *) echo "auto" ;;
    esac
}

wakeup_target_from_string() {
    case "${1,,}" in
        enabled|enable|on|1|true|yes) echo "enabled" ;;
        *) echo "disabled" ;;
    esac
}

apply_usb_runtime_pm() {
    local usb_target=$1
    shift

    local total_paths=0
    local writable_paths=0
    local success_paths=0
    local failed_paths=0
    local control_path

    for control_path in "$@"; do
        ((total_paths += 1))

        if [[ ! -w "$control_path" ]]; then
            echo "USB runtime PM path not writable: ${control_path}"
            continue
        fi

        ((writable_paths += 1))
        if echo "$usb_target" > "$control_path" 2>/dev/null; then
            ((success_paths += 1))
        else
            ((failed_paths += 1))
            echo "Failed to write USB runtime PM target ${usb_target} to ${control_path}."
        fi
    done

    if [[ "$total_paths" -eq 0 ]]; then
        echo "USB runtime PM enabled but no USB power/control paths matched the configured USB device glob."
        return 0
    fi

    if [[ "$success_paths" -gt 0 ]]; then
        echo "USB runtime PM target ${usb_target} applied to ${success_paths}/${writable_paths} writable path(s)."
    fi

    if [[ "$failed_paths" -gt 0 ]]; then
        echo "USB runtime PM write failures: ${failed_paths} path(s)."
    fi

    if [[ "$writable_paths" -eq 0 ]]; then
        echo "USB runtime PM found ${total_paths} path(s), but none were writable."
    fi
}

apply_usb_wakeup() {
    local usb_wakeup_target=$1
    shift

    local total_paths=0
    local writable_paths=0
    local success_paths=0
    local failed_paths=0
    local wakeup_path

    for wakeup_path in "$@"; do
        ((total_paths += 1))

        if [[ ! -w "$wakeup_path" ]]; then
            echo "USB wakeup path not writable: ${wakeup_path}"
            continue
        fi

        ((writable_paths += 1))
        if echo "$usb_wakeup_target" > "$wakeup_path" 2>/dev/null; then
            ((success_paths += 1))
        else
            ((failed_paths += 1))
            echo "Failed to write USB wakeup target ${usb_wakeup_target} to ${wakeup_path}."
        fi
    done

    if [[ "$total_paths" -eq 0 ]]; then
        echo "USB wakeup optimization enabled but no USB power/wakeup paths matched the configured USB device glob."
        return 0
    fi

    if [[ "$success_paths" -gt 0 ]]; then
        echo "USB wakeup target ${usb_wakeup_target} applied to ${success_paths}/${writable_paths} writable path(s)."
    fi

    if [[ "$failed_paths" -gt 0 ]]; then
        echo "USB wakeup write failures: ${failed_paths} path(s)."
    fi

    if [[ "$writable_paths" -eq 0 ]]; then
        echo "USB wakeup found ${total_paths} path(s), but none were writable."
    fi
}

collect_usb_power_paths() {
    local suffix=$1
    local matched_paths=()
    local usb_device

    shopt -s nullglob
    for usb_device in /sys/bus/usb/devices/${device_glob}; do
        if [[ -e "${usb_device}/power/${suffix}" ]]; then
            matched_paths+=("${usb_device}/power/${suffix}")
        fi
    done
    shopt -u nullglob

    if [[ "${#matched_paths[@]}" -gt 0 ]]; then
        printf '%s\n' "${matched_paths[@]}"
    fi
}

enable_usb=$(bool_from_string "$(read_config_value "ENABLE_USB_AUTOSUSPEND_OPTIMIZATION" "1")")
target=$(runtime_target_from_string "$(read_config_value "USB_RUNTIME_PM_TARGET" "auto")")
enable_usb_wakeup=$(bool_from_string "$(read_config_value "ENABLE_USB_WAKEUP_OPTIMIZATION" "1")")
usb_wakeup_target=$(wakeup_target_from_string "$(read_config_value "USB_WAKEUP_TARGET" "disabled")")
device_glob=$(read_config_value "USB_DEVICE_GLOB" "*")
[[ -n "$device_glob" ]] || device_glob="*"
usb_auto_startup=$(bool_from_string "$(read_config_value "USB_AUTO_EXECUTE_ON_STARTUP" "0")")

echo "USB setting USB_AUTO_EXECUTE_ON_STARTUP=${usb_auto_startup}."
echo "USB setting ENABLE_USB_AUTOSUSPEND_OPTIMIZATION=${enable_usb}."
echo "USB setting USB_RUNTIME_PM_TARGET=${target}."
echo "USB setting ENABLE_USB_WAKEUP_OPTIMIZATION=${enable_usb_wakeup}."
echo "USB setting USB_WAKEUP_TARGET=${usb_wakeup_target}."
echo "USB setting USB_DEVICE_GLOB=${device_glob}."

mapfile -t usb_control_paths < <(collect_usb_power_paths "control")
mapfile -t usb_wakeup_paths < <(collect_usb_power_paths "wakeup")

echo "USB power/control paths matched: ${#usb_control_paths[@]}."
echo "USB power/wakeup paths matched: ${#usb_wakeup_paths[@]}."

if [[ "$enable_usb" -eq 1 ]]; then
    if [[ "$target" == "disabled" ]]; then
        echo "USB runtime PM target set to disabled; no USB runtime PM changes applied."
    else
        apply_usb_runtime_pm "$target" "${usb_control_paths[@]}"
    fi
else
    echo "USB autosuspend optimization disabled; no USB runtime PM changes applied."
fi

if [[ "$enable_usb_wakeup" -eq 1 ]]; then
    apply_usb_wakeup "$usb_wakeup_target" "${usb_wakeup_paths[@]}"
else
    echo "USB wakeup optimization disabled; no USB wakeup changes applied."
fi
