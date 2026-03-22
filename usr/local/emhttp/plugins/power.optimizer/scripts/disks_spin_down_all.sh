#!/bin/bash

enable_timestamped_output() {
    exec > >(while IFS= read -r line; do
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done) 2>&1
}

enable_timestamped_output

echo "Starting spin-down request for all /dev/sd? devices."

if [[ ! -r /var/local/emhttp/disks.ini ]]; then
    echo "Missing /var/local/emhttp/disks.ini; unable to map devices to Unraid disk names."
    exit 1
fi

requested=0
skipped=0
failed=0

find_disk_name_for_device() {
    local short_dev=$1

    awk -v target="$short_dev" '
        /^name="/ {
            current_name = $0
            sub(/^name="/, "", current_name)
            sub(/"$/, "", current_name)
            next
        }

        /^device="/ {
            current_device = $0
            sub(/^device="/, "", current_device)
            sub(/"$/, "", current_device)

            if (current_device == target && current_name != "") {
                print current_name
                exit
            }
        }
    ' /var/local/emhttp/disks.ini
}

shopt -s nullglob
for dev in /dev/sd?; do
    short_dev="${dev##*/}"

    disk_name=$(find_disk_name_for_device "$short_dev")

    if [[ -z "$disk_name" ]]; then
        echo "Skipping ${dev}: no matching disk name found in disks.ini."
        skipped=$((skipped + 1))
        continue
    fi

    if /usr/local/sbin/emcmd "cmdSpindown=${disk_name}" >/dev/null 2>&1; then
        echo "Spin-down requested for ${dev} (${disk_name})."
        requested=$((requested + 1))
    else
        echo "Failed to request spin-down for ${dev} (${disk_name})."
        failed=$((failed + 1))
    fi
done
shopt -u nullglob

echo "Spin-down summary: requested=${requested}, skipped=${skipped}, failed=${failed}."
