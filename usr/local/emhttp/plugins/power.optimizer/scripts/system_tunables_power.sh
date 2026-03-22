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

int_in_range() {
    local raw=$1
    local default_value=$2
    local min=$3
    local max=$4

    if [[ ! "$raw" =~ ^-?[0-9]+$ ]]; then
        echo "$default_value"
        return 0
    fi

    if (( raw < min )); then
        echo "$min"
        return 0
    fi

    if (( raw > max )); then
        echo "$max"
        return 0
    fi

    echo "$raw"
}

read_memtotal_bytes() {
    local mem_total_kb

    [[ -r /proc/meminfo ]] || {
        echo 0
        return 0
    }

    mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    if [[ ! "$mem_total_kb" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi

    echo $(( mem_total_kb * 1024 ))
}

percent_of_total_bytes() {
    local percent=$1
    local total_bytes=$2

    if (( percent <= 0 || total_bytes <= 0 )); then
        echo 0
        return 0
    fi

    echo $(( total_bytes * percent / 100 ))
}

enable_audio_codec_pm=$(bool_from_string "$(read_config_value "ENABLE_AUDIO_CODEC_PM_OPTIMIZATION" "1")")
audio_codec_power_save_seconds=$(int_in_range "$(read_config_value "AUDIO_CODEC_POWER_SAVE_SECONDS" "1")" 1 0 60)

enable_nmi_watchdog=$(bool_from_string "$(read_config_value "ENABLE_NMI_WATCHDOG_OPTIMIZATION" "1")")
nmi_watchdog_target=$(int_in_range "$(read_config_value "NMI_WATCHDOG_TARGET" "0")" 0 0 1)

power_aware_scheduler_mode=$(int_in_range "$(read_config_value "POWER_AWARE_CPU_SCHEDULER_MODE" "2")" 2 0 2)

enable_vm_writeback_timeout=$(bool_from_string "$(read_config_value "ENABLE_VM_WRITEBACK_TIMEOUT_OPTIMIZATION" "1")")
vm_dirty_writeback_centisecs=$(int_in_range "$(read_config_value "VM_DIRTY_WRITEBACK_CENTISECS" "1500")" 1500 100 60000)
vfs_cache_pressure=$(int_in_range "$(read_config_value "VFS_CACHE_PRESSURE" "1")" 1 1 10000)
vfs_cache_max_age=$(int_in_range "$(read_config_value "VFS_CACHE_MAX_AGE" "60000")" 60000 1 31536000)
zfs_arc_min_percent=$(int_in_range "$(read_config_value "ZFS_ARC_MIN_PERCENT" "10")" 10 0 100)
zfs_arc_max_percent=$(int_in_range "$(read_config_value "ZFS_ARC_MAX_PERCENT" "40")" 40 0 100)

if [[ "$zfs_arc_min_percent" -gt 0 && "$zfs_arc_max_percent" -gt 0 && "$zfs_arc_min_percent" -gt "$zfs_arc_max_percent" ]]; then
    echo "ZFS ARC min percent (${zfs_arc_min_percent}%) was above max (${zfs_arc_max_percent}%); clamping min to max."
    zfs_arc_min_percent="$zfs_arc_max_percent"
fi

system_memory_bytes=$(read_memtotal_bytes)
zfs_arc_min_bytes=$(percent_of_total_bytes "$zfs_arc_min_percent" "$system_memory_bytes")
zfs_arc_max_bytes=$(percent_of_total_bytes "$zfs_arc_max_percent" "$system_memory_bytes")

system_auto_startup=$(bool_from_string "$(read_config_value "SYSTEM_AUTO_EXECUTE_ON_STARTUP" "0")")
disable_nmi_watchdog=0
if [[ "$nmi_watchdog_target" -eq 0 ]]; then
    disable_nmi_watchdog=1
fi

echo "System setting SYSTEM_AUTO_EXECUTE_ON_STARTUP=${system_auto_startup}."
echo "System setting ENABLE_AUDIO_CODEC_PM_OPTIMIZATION=${enable_audio_codec_pm}."
echo "System setting AUDIO_CODEC_POWER_SAVE_SECONDS=${audio_codec_power_save_seconds}."
echo "System setting DISABLE_NMI_WATCHDOG=${disable_nmi_watchdog}."
echo "System setting POWER_AWARE_CPU_SCHEDULER_MODE=${power_aware_scheduler_mode}."
echo "System setting ENABLE_VM_WRITEBACK_TIMEOUT_OPTIMIZATION=${enable_vm_writeback_timeout}."
echo "System setting VM_DIRTY_WRITEBACK_CENTISECS=${vm_dirty_writeback_centisecs}."
echo "System setting VFS_CACHE_PRESSURE=${vfs_cache_pressure}."
echo "System setting VFS_CACHE_MAX_AGE=${vfs_cache_max_age}."
echo "System setting ZFS_ARC_MIN_PERCENT=${zfs_arc_min_percent}."
echo "System setting ZFS_ARC_MAX_PERCENT=${zfs_arc_max_percent}."

write_value_with_status() {
    local path=$1
    local value=$2
    local success_message=$3
    local failure_message=$4
    local not_writable_message=$5

    if [[ -w "$path" ]]; then
        if echo "$value" > "$path" 2>/dev/null; then
            echo "$success_message"
        else
            echo "$failure_message"
        fi
    else
        echo "$not_writable_message"
    fi
}

if [[ "$enable_audio_codec_pm" -eq 1 ]]; then
    write_value_with_status \
        /sys/module/snd_hda_intel/parameters/power_save \
        "$audio_codec_power_save_seconds" \
        "Audio codec power_save set to ${audio_codec_power_save_seconds}." \
        "Failed to set audio codec power_save to ${audio_codec_power_save_seconds}." \
        "Audio codec power_save path is not writable on this system."
else
    echo "Audio codec power management disabled; no audio codec changes applied."
fi

if [[ "$enable_nmi_watchdog" -eq 1 ]]; then
    write_value_with_status \
        /proc/sys/kernel/nmi_watchdog \
        "$nmi_watchdog_target" \
        "kernel.nmi_watchdog set to ${nmi_watchdog_target}." \
        "Failed to set kernel.nmi_watchdog to ${nmi_watchdog_target}." \
        "kernel.nmi_watchdog path is not writable on this system."
else
    echo "NMI watchdog optimization disabled; no nmi_watchdog changes applied."
fi

if [[ "$enable_vm_writeback_timeout" -eq 1 ]]; then
    write_value_with_status \
        /proc/sys/vm/dirty_writeback_centisecs \
        "$vm_dirty_writeback_centisecs" \
        "vm.dirty_writeback_centisecs set to ${vm_dirty_writeback_centisecs}." \
        "Failed to set vm.dirty_writeback_centisecs to ${vm_dirty_writeback_centisecs}." \
        "vm.dirty_writeback_centisecs path is not writable on this system."
else
    echo "VM writeback timeout optimization disabled; no vm.dirty_writeback_centisecs changes applied."
fi

write_value_with_status \
    /proc/sys/vm/vfs_cache_pressure \
    "$vfs_cache_pressure" \
    "vm.vfs_cache_pressure set to ${vfs_cache_pressure}." \
    "Failed to set vm.vfs_cache_pressure to ${vfs_cache_pressure}." \
    "vm.vfs_cache_pressure path is not writable on this system."

write_value_with_status \
    /proc/sys/vm/vfs_cache_max_age \
    "$vfs_cache_max_age" \
    "vm.vfs_cache_max_age set to ${vfs_cache_max_age}." \
    "Failed to set vm.vfs_cache_max_age to ${vfs_cache_max_age}." \
    "vm.vfs_cache_max_age path is not writable on this system."

if [[ "$zfs_arc_min_percent" -eq 0 ]]; then
    echo "ZFS ARC min percent is 0; keeping existing zfs_arc_min value."
elif [[ "$system_memory_bytes" -gt 0 ]]; then
    write_value_with_status \
        /sys/module/zfs/parameters/zfs_arc_min \
        "$zfs_arc_min_bytes" \
        "zfs_arc_min set to ${zfs_arc_min_bytes} bytes (${zfs_arc_min_percent}% of RAM)." \
        "Failed to set zfs_arc_min to ${zfs_arc_min_bytes} bytes (${zfs_arc_min_percent}% of RAM)." \
        "zfs_arc_min path is not writable on this system."
else
    echo "Unable to read total system memory from /proc/meminfo; skipping zfs_arc_min tuning."
fi

if [[ "$zfs_arc_max_percent" -eq 0 ]]; then
    echo "ZFS ARC max percent is 0; keeping existing zfs_arc_max value."
elif [[ "$system_memory_bytes" -gt 0 ]]; then
    write_value_with_status \
        /sys/module/zfs/parameters/zfs_arc_max \
        "$zfs_arc_max_bytes" \
        "zfs_arc_max set to ${zfs_arc_max_bytes} bytes (${zfs_arc_max_percent}% of RAM)." \
        "Failed to set zfs_arc_max to ${zfs_arc_max_bytes} bytes (${zfs_arc_max_percent}% of RAM)." \
        "zfs_arc_max path is not writable on this system."
else
    echo "Unable to read total system memory from /proc/meminfo; skipping zfs_arc_max tuning."
fi

write_value_with_status \
    /sys/devices/system/cpu/sched_mc_power_savings \
    "$power_aware_scheduler_mode" \
    "sched_mc_power_savings set to ${power_aware_scheduler_mode}." \
    "Failed to set sched_mc_power_savings to ${power_aware_scheduler_mode}." \
    "sched_mc_power_savings path is not writable on this system."
