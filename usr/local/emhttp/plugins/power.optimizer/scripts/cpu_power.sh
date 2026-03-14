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

governor_from_string() {
    case "${1,,}" in
        powersave|ondemand|performance|conservative|schedutil) echo "${1,,}" ;;
        *) echo "powersave" ;;
    esac
}

governor_mode_from_string() {
    case "${1,,}" in
        disabled|off) echo "disabled" ;;
        powersave|ondemand|performance|conservative|schedutil) echo "${1,,}" ;;
        *) echo "disabled" ;;
    esac
}

turbo_mode_from_string() {
    case "${1,,}" in
        force_enabled|enabled|enable|on|1|true) echo "force_enabled" ;;
        force_disabled|disable|target_disabled|0|false) echo "force_disabled" ;;
        disabled|off|none) echo "disabled" ;;
        *) echo "disabled" ;;
    esac
}

legacy_enable_governor=$(bool_from_string "$(read_config_value "ENABLE_CPU_GOVERNOR_OPTIMIZATION" "1")")
legacy_enable_turbo=$(bool_from_string "$(read_config_value "ENABLE_CPU_TURBO_OPTIMIZATION" "0")")
legacy_governor_target=$(governor_from_string "$(read_config_value "CPU_GOVERNOR_TARGET" "powersave")")
legacy_turbo_target=$(bool_from_string "$(read_config_value "CPU_TURBO_TARGET" "0")")

legacy_governor_mode="disabled"
if [[ "$legacy_enable_governor" -eq 1 ]]; then
    legacy_governor_mode="$legacy_governor_target"
fi

legacy_turbo_mode="disabled"
if [[ "$legacy_enable_turbo" -eq 1 ]]; then
    if [[ "$legacy_turbo_target" -eq 1 ]]; then
        legacy_turbo_mode="force_enabled"
    else
        legacy_turbo_mode="force_disabled"
    fi
fi

governor_mode=$(governor_mode_from_string "$(read_config_value "CPU_GOVERNOR_MODE" "$legacy_governor_mode")")
turbo_mode=$(turbo_mode_from_string "$(read_config_value "CPU_TURBO_MODE" "$legacy_turbo_mode")")
cpu_auto_startup=$(bool_from_string "$(read_config_value "CPU_AUTO_EXECUTE_ON_STARTUP" "0")")

echo "CPU setting CPU_AUTO_EXECUTE_ON_STARTUP=${cpu_auto_startup}."
echo "CPU setting CPU_GOVERNOR_MODE=${governor_mode}."
echo "CPU setting CPU_TURBO_MODE=${turbo_mode}."

if [[ "$governor_mode" != "disabled" ]]; then
    /etc/rc.d/rc.cpufreq "$governor_mode" >/dev/null 2>&1 || true
    echo "CPU governor set to ${governor_mode}."
else
    echo "CPU governor optimization disabled; no governor changes applied."
fi

if [[ "$turbo_mode" != "disabled" ]]; then
    if [[ "$turbo_mode" == "force_enabled" ]]; then
        if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
            echo "0" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
        fi

        if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
            echo "1" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        fi
    fi

    if [[ "$turbo_mode" == "force_disabled" ]]; then
        if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
            echo "1" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
        fi

        if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
            echo "0" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        fi
    fi

    echo "CPU turbo state updated (mode=${turbo_mode})."
else
    echo "CPU turbo optimization disabled; no turbo changes applied."
fi
