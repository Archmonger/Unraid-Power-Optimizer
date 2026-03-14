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
        on) echo "on" ;;
        *) echo "auto" ;;
    esac
}

runtime_pm_mode_from_string() {
    case "${1,,}" in
        disabled|off) echo "disabled" ;;
        on) echo "on" ;;
        *) echo "auto" ;;
    esac
}

legacy_enable_i2c_pm=$(bool_from_string "$(read_config_value "ENABLE_I2C_RUNTIME_PM_OPTIMIZATION" "1")")
legacy_target=$(runtime_target_from_string "$(read_config_value "I2C_RUNTIME_PM_TARGET" "on")")

legacy_mode="disabled"
if [[ "$legacy_enable_i2c_pm" -eq 1 ]]; then
    legacy_mode="$legacy_target"
fi

mode=$(runtime_pm_mode_from_string "$(read_config_value "I2C_RUNTIME_PM_MODE" "$legacy_mode")")
device_glob=$(read_config_value "I2C_DEVICE_GLOB" "i2c-*")
[[ -n "$device_glob" ]] || device_glob="i2c-*"
i2c_auto_startup=$(bool_from_string "$(read_config_value "I2C_AUTO_EXECUTE_ON_STARTUP" "0")")

echo "I2C setting I2C_AUTO_EXECUTE_ON_STARTUP=${i2c_auto_startup}."
echo "I2C setting I2C_RUNTIME_PM_MODE=${mode}."
echo "I2C setting I2C_DEVICE_GLOB=${device_glob}."

if [[ "$mode" != "disabled" ]]; then
    applied_count=0
    for path in /sys/bus/i2c/devices/${device_glob}/device/power/control; do
        [[ -w "$path" ]] || continue
        echo "$mode" > "$path" 2>/dev/null || true
        applied_count=$((applied_count + 1))
    done

    if [[ "$applied_count" -gt 0 ]]; then
        echo "I2C runtime PM set to ${mode} for ${device_glob} (${applied_count} path(s))."
    else
        echo "I2C runtime PM enabled but no writable I2C power/control paths matched ${device_glob}."
    fi
else
    echo "I2C runtime PM optimization disabled; no I2C runtime PM changes applied."
fi
