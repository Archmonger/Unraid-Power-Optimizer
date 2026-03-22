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

auto_eth_interfaces() {
    local path
    TARGET_INTERFACES=()
    for path in /sys/class/net/eth?; do
        [[ -e "$path" ]] || continue
        TARGET_INTERFACES+=("$(basename "$path")")
    done
}

enable_eee=$(bool_from_string "$(read_config_value "ENABLE_ETHERNET_EEE_OPTIMIZATION" "1")")
enable_wol=$(bool_from_string "$(read_config_value "ENABLE_ETHERNET_WOL_OPTIMIZATION" "1")")
ethernet_auto_startup=$(bool_from_string "$(read_config_value "ETHERNET_AUTO_EXECUTE_ON_STARTUP" "0")")
auto_eth_interfaces

echo "Ethernet setting ETHERNET_AUTO_EXECUTE_ON_STARTUP=${ethernet_auto_startup}."
echo "Ethernet setting ENABLE_ETHERNET_EEE_OPTIMIZATION=${enable_eee}."
echo "Ethernet setting ENABLE_ETHERNET_WOL_OPTIMIZATION=${enable_wol}."

if [[ "$enable_eee" -eq 0 ]]; then
    echo "EEE optimization disabled; no EEE changes applied."
fi

if [[ "$enable_wol" -eq 0 ]]; then
    echo "Wake on LAN optimization disabled; no WOL changes applied."
fi

if [[ "${#TARGET_INTERFACES[@]}" -eq 0 ]]; then
    echo "No ethX interfaces found; no Ethernet power changes applied."
fi

for dev in "${TARGET_INTERFACES[@]}"; do
    if [[ "$enable_eee" -eq 1 ]]; then
        if [[ "$(ethtool --show-eee "$dev" 2>/dev/null | grep -c "Supported EEE link modes")" -ge 1 ]]; then
            ethtool --set-eee "$dev" eee on >/dev/null 2>&1 || true
            echo "EEE set to on on ${dev}."
        else
            echo "EEE not supported on ${dev}; skipped EEE update."
        fi
    fi

    if [[ "$enable_wol" -eq 1 ]]; then
        ethtool -s "$dev" wol d >/dev/null 2>&1 || true
        echo "Wake on LAN set to d on ${dev}."
    fi
done
