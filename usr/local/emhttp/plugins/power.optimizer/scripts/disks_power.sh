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

runtime_pm_mode_from_string() {
    case "${1,,}" in
        disabled|off) echo "disabled" ;;
        *) echo "auto" ;;
    esac
}

sata_lpm_mode_from_string() {
    case "${1,,}" in
        disabled|off) echo "disabled" ;;
        max_performance|max) echo "max_performance" ;;
        min_power|min) echo "min_power" ;;
        *) echo "med_power_with_dipm" ;;
    esac
}

nvme_apst_mode_from_string() {
    case "${1,,}" in
        disabled|off) echo "disabled" ;;
        *) echo "enabled" ;;
    esac
}

sata_mode=$(sata_lpm_mode_from_string "$(read_config_value "SATA_LPM_MODE" "min_power")")
disks_auto_startup=$(bool_from_string "$(read_config_value "DISKS_AUTO_EXECUTE_ON_STARTUP" "0")")

disk_mode=$(runtime_pm_mode_from_string "$(read_config_value "DISK_RUNTIME_PM_MODE" "auto")")
ata_mode=$(runtime_pm_mode_from_string "$(read_config_value "ATA_RUNTIME_PM_MODE" "auto")")
nvme_apst_mode=$(nvme_apst_mode_from_string "$(read_config_value "NVME_APST_MODE" "enabled")")
nvme_runtime_pm_mode=$(runtime_pm_mode_from_string "$(read_config_value "NVME_RUNTIME_PM_MODE" "auto")")

echo "Disks setting DISKS_AUTO_EXECUTE_ON_STARTUP=${disks_auto_startup}."
echo "Disks setting SATA_LPM_MODE=${sata_mode}."
echo "Disks setting DISK_RUNTIME_PM_MODE=${disk_mode}."
echo "Disks setting ATA_RUNTIME_PM_MODE=${ata_mode}."
echo "Disks setting NVME_APST_MODE=${nvme_apst_mode}."
echo "Disks setting NVME_RUNTIME_PM_MODE=${nvme_runtime_pm_mode}."

collect_sysfs_paths() {
    local -a matched_paths=()
    local pattern path

    shopt -s nullglob
    for pattern in "$@"; do
        for path in $pattern; do
            [[ -e "$path" ]] || continue
            matched_paths+=("$path")
        done
    done
    shopt -u nullglob

    if [[ "${#matched_paths[@]}" -gt 0 ]]; then
        printf '%s\n' "${matched_paths[@]}" | sort -u
    fi
}

collect_ata_controller_power_paths() {
    local -a matched_paths=()
    local controller_path ata_path

    shopt -s nullglob
    for controller_path in /sys/bus/pci/devices/*; do
        [[ -d "$controller_path" ]] || continue
        for ata_path in "$controller_path"/ata*; do
            [[ -d "$ata_path" ]] || continue
            if [[ -e "$controller_path/power/control" ]]; then
                matched_paths+=("$controller_path/power/control")
            fi
            break
        done
    done
    shopt -u nullglob

    if [[ "${#matched_paths[@]}" -gt 0 ]]; then
        printf '%s\n' "${matched_paths[@]}" | sort -u
    fi
}

read_path_value() {
    local path=$1
    local raw

    if [[ ! -r "$path" ]]; then
        echo ""
        return 0
    fi

    raw=$(cat "$path" 2>/dev/null)
    raw=${raw//$'\r'/}
    raw=${raw//$'\n'/ }
    raw=${raw## }
    raw=${raw%% }
    echo "$raw"
}

path_value_matches() {
    local path=$1
    local expected=$2
    local current

    current=$(read_path_value "$path")
    if [[ "$current" == "$expected" ]]; then
        return 0
    fi

    if [[ "$current" == *"[$expected]"* ]]; then
        return 0
    fi

    return 1
}

apply_path_candidates_with_verification() {
    local label=$1
    local path=$2
    shift 2

    local candidate
    local current

    if [[ ! -w "$path" ]]; then
        if [[ "$#" -gt 0 ]] && path_value_matches "$path" "$1"; then
            echo "$label already set to $1 at ${path} (read-only path)."
            return 0
        fi

        echo "$label path not writable: ${path}"
        return 1
    fi

    for candidate in "$@"; do
        if echo "$candidate" > "$path" 2>/dev/null && path_value_matches "$path" "$candidate"; then
            echo "$label set to ${candidate} at ${path}."
            return 0
        fi
    done

    current=$(read_path_value "$path")
    if [[ -n "$current" ]]; then
        echo "Failed to set ${label} at ${path}. Current value: ${current}."
    else
        echo "Failed to set ${label} at ${path}."
    fi
    return 1
}

apply_sata_lpm_mode() {
    local requested_mode=$1
    local -a candidate_modes sata_paths
    local writable_count=0
    local success_count=0
    local failure_count=0
    local path candidate applied_mode

    case "$requested_mode" in
        min_power)
            candidate_modes=("med_power_with_dipm" "medium_power" "min_power")
            ;;
        med_power_with_dipm)
            candidate_modes=("med_power_with_dipm" "medium_power" "min_power")
            ;;
        max_performance)
            candidate_modes=("max_performance")
            ;;
        *)
            candidate_modes=("$requested_mode")
            ;;
    esac

    mapfile -t sata_paths < <(collect_sysfs_paths /sys/class/scsi_host/host*/link_power_management_policy)
    if [[ "${#sata_paths[@]}" -eq 0 ]]; then
        echo "SATA LPM enabled but no host link_power_management_policy paths were found."
        return 0
    fi

    for path in "${sata_paths[@]}"; do
        if [[ -w "$path" ]]; then
            writable_count=$((writable_count + 1))
        fi

        if apply_path_candidates_with_verification "SATA LPM" "$path" "${candidate_modes[@]}"; then
            applied_mode=$(read_path_value "$path")
            success_count=$((success_count + 1))
            if [[ "$applied_mode" != "$requested_mode" ]]; then
                echo "SATA LPM fallback in use at ${path}: requested ${requested_mode}, effective ${applied_mode}."
            fi
        else
            failure_count=$((failure_count + 1))
            echo "Failed to set SATA LPM at ${path} (requested ${requested_mode})."
        fi
    done

    if [[ "$writable_count" -eq 0 ]]; then
        echo "SATA LPM enabled but no writable host link_power_management_policy paths were found."
        return 0
    fi

    echo "SATA link power management requested ${requested_mode}; ${success_count}/${writable_count} writable host path(s) updated, ${failure_count} failed."
}

apply_runtime_pm_mode() {
    local label=$1
    local requested_mode=$2
    shift 2

    local -a target_paths
    local writable_count=0
    local success_count=0
    local failure_count=0
    local path

    mapfile -t target_paths < <(collect_sysfs_paths "$@")
    if [[ "${#target_paths[@]}" -eq 0 ]]; then
        echo "${label} enabled but no target power/control paths were found."
        return 0
    fi

    for path in "${target_paths[@]}"; do
        if [[ -w "$path" ]]; then
            writable_count=$((writable_count + 1))
        fi

        if apply_path_candidates_with_verification "$label" "$path" "$requested_mode"; then
            success_count=$((success_count + 1))
        else
            failure_count=$((failure_count + 1))
        fi
    done

    if [[ "$writable_count" -eq 0 ]]; then
        echo "${label} enabled but no writable target power/control paths were found."
        return 0
    fi

    echo "${label} requested ${requested_mode}; ${success_count}/${writable_count} writable path(s) updated, ${failure_count} failed."
}

apply_nvme_apst_mode() {
    local requested_mode=$1
    local apst_path="/sys/module/nvme_core/parameters/default_ps_max_latency_us"
    local current_latency

    if [[ ! -e "$apst_path" ]]; then
        echo "NVMe APST setting unsupported on this kernel (missing ${apst_path})."
        return 0
    fi

    if [[ "$requested_mode" == "disabled" ]]; then
        if apply_path_candidates_with_verification "NVMe APST" "$apst_path" "0"; then
            echo "NVMe APST disabled."
        fi
        return 0
    fi

    current_latency=$(read_path_value "$apst_path")
    if [[ "$current_latency" =~ ^[0-9]+$ ]] && (( current_latency > 0 )); then
        echo "NVMe APST already enabled (default_ps_max_latency_us=${current_latency})."
        return 0
    fi

    if apply_path_candidates_with_verification "NVMe APST" "$apst_path" "5500"; then
        echo "NVMe APST enabled (default_ps_max_latency_us=5500)."
    fi
}

if [[ "$sata_mode" != "disabled" ]]; then
    apply_sata_lpm_mode "$sata_mode"
else
    echo "SATA link power management policy disabled; no SATA LPM changes applied."
fi

if [[ "$disk_mode" != "disabled" ]]; then
    apply_runtime_pm_mode "Disk runtime PM" "$disk_mode" \
        /sys/block/sd*/device/power/control \
        /sys/class/scsi_disk/*/device/power/control \
        /sys/class/scsi_device/*/device/power/control
else
    echo "Disk runtime PM optimization disabled; no disk runtime PM changes applied."
fi

if [[ "$ata_mode" != "disabled" ]]; then
    mapfile -t ata_controller_paths < <(collect_ata_controller_power_paths)

    apply_runtime_pm_mode "ATA runtime PM" "$ata_mode" \
        /sys/bus/pci/devices/????:??:??.?/ata*/power/control \
        /sys/class/ata_port/ata*/power/control \
        /sys/class/ata_port/ata*/device/power/control \
        /sys/class/scsi_host/host*/device/power/control \
        /sys/class/scsi_host/host*/power/control \
        "${ata_controller_paths[@]}"
else
    echo "ATA runtime PM optimization disabled; no ATA runtime PM changes applied."
fi

apply_nvme_apst_mode "$nvme_apst_mode"

if [[ "$nvme_runtime_pm_mode" != "disabled" ]]; then
    apply_runtime_pm_mode "NVMe runtime PM" "$nvme_runtime_pm_mode" \
        /sys/class/nvme/nvme*/device/power/control \
        /sys/class/nvme-subsystem/nvme-subsys*/device/power/control \
        /sys/class/nvme-fabrics/*/power/control \
        /sys/class/nvme-fabrics/ctl/power/control \
        /sys/class/nvme-fabrics/ctl*/power/control
else
    echo "NVMe runtime PM optimization disabled; no NVMe runtime PM changes applied."
fi
