#!/usr/bin/env bash
# Only the three image files owned by this lab may be provisioned.
set -Eeuo pipefail
umask 077

LAB=/mnt/raid-lab
MD=/dev/md/capstone
VG=vg_data
LV=lv_logs
TAG=capstone_hw2
IMAGE_BYTES=$((512 * 1024 * 1024))

die() { printf 'storage: %s\n' "$*" >&2; exit 1; }
trim() { tr -d '[:space:]'; }
signature() { wipefs --noheadings --output TYPE "$1" | sort -u; }
md_uuid() { mdadm --detail --export "$1" 2>/dev/null | sed -n 's/^MD_UUID=//p'; }
member_uuid() { mdadm --examine --export "$1" 2>/dev/null | sed -n 's/^MD_UUID=//p'; }
owned_file() {
    [[ -f "$1" && ! -L "$1" && $(stat -c %u "$1") == 0 ]] || die "Unsafe file: $1"
}

[[ $EUID == 0 ]] || die 'Run as root.'
for command in mdadm losetup wipefs pvcreate pvs vgcreate vgs vgchange lvcreate lvs mkfs.ext4 flock; do
    command -v "$command" >/dev/null || die "Missing command: $command"
done
exec 9>/run/lock/my-app-storage.lock
flock -n 9 || die 'Another storage setup is running.'

[[ ! -L "$LAB" ]] || die "$LAB must not be a symlink."
if [[ ! -d "$LAB" ]]; then
    install -d -m 0700 "$LAB"
fi
[[ $(stat -c %u "$LAB") == 0 ]] || die "$LAB must belong to root."
if [[ ! -e "$LAB/.owner" ]]; then
    [[ -z $(find "$LAB" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "Refusing to adopt nonempty $LAB."
    printf '%s\n' "$TAG" > "$LAB/.owner"
fi
owned_file "$LAB/.owner"
[[ $(cat "$LAB/.owner") == "$TAG" ]] || die 'Storage owner marker does not match.'
[[ ! -L "$LAB/raid.uuid" && ! -L "$LAB/pv.uuid" ]] || die 'UUID files must not be symlinks.'

loops=()
for number in 1 2 3; do
    file="$LAB/disk${number}.img"
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        [[ ! -e "$LAB/raid.uuid" && ! -e "$LAB/pv.uuid" ]] || die "Missing existing image: $file"
        truncate -s "$IMAGE_BYTES" "$file"
    fi
    owned_file "$file"
    [[ $(stat -c %s "$file") == "$IMAGE_BYTES" ]] || die "Unexpected image size: $file"
    mapfile -t attached < <(losetup --associated "$file" --noheadings --output NAME)
    (( ${#attached[@]} <= 1 )) || die "Multiple loop devices refer to $file."
    if (( ${#attached[@]} == 0 )); then
        loops+=("$(losetup --find --show "$file")")
    else
        loops+=("${attached[0]}")
    fi
    [[ $(blockdev --getsize64 "${loops[-1]}") == "$IMAGE_BYTES" ]] || die "Unexpected loop mapping for $file."
done
RAID_LOOPS=("${loops[0]}" "${loops[1]}")
PV=${loops[2]}
if command -v udevadm >/dev/null; then udevadm settle; fi

if [[ ! -e "$LAB/raid.uuid" ]]; then
    # Save the intended UUID before creating the array so interrupted runs can resume.
    [[ -z $(signature "${RAID_LOOPS[0]}") && -z $(signature "${RAID_LOOPS[1]}") ]] || die 'Unowned RAID signatures found.'
    read -r random_uuid < /proc/sys/kernel/random/uuid
    random_uuid=${random_uuid//-/}
    printf '%s:%s:%s:%s\n' "${random_uuid:0:8}" "${random_uuid:8:8}" "${random_uuid:16:8}" "${random_uuid:24:8}" > "$LAB/raid.uuid"
fi
owned_file "$LAB/raid.uuid"
RAID_UUID=$(cat "$LAB/raid.uuid")
[[ $RAID_UUID =~ ^[0-9a-f]{8}(:[0-9a-f]{8}){3}$ ]] || die 'Invalid saved RAID UUID.'

raid_signature=$(signature "${RAID_LOOPS[0]}")
[[ $(signature "${RAID_LOOPS[1]}") == "$raid_signature" ]] || die 'RAID member signatures differ.'
if [[ $raid_signature == linux_raid_member ]]; then
    for device in "${RAID_LOOPS[@]}"; do
        [[ $(member_uuid "$device") == "$RAID_UUID" ]] || die "Foreign RAID member: $device"
    done
elif [[ -n $raid_signature ]]; then
    die "Unexpected RAID member signature: $raid_signature"
fi

# udev can assemble the owned array under another md number on boot.
active_md=
for metadata in /sys/block/md*/md; do
    [[ -d "$metadata" ]] || continue
    device="/dev/$(basename "$(dirname "$metadata")")"
    if [[ $(md_uuid "$device" || true) == "$RAID_UUID" ]]; then
        [[ -z $active_md ]] || die 'Multiple arrays have the saved RAID UUID.'
        active_md=$device
    fi
done
if [[ -e "$MD" || -L "$MD" ]]; then
    [[ -n $active_md && $(readlink -f "$MD") == "$active_md" ]] || die "Foreign or stale array name: $MD"
fi
if [[ -z $active_md ]]; then
    if [[ -z $raid_signature ]]; then
        mdadm --create "$MD" --metadata=1.2 --name=capstone --uuid="$RAID_UUID" \
            --level=1 --raid-devices=2 --run "${RAID_LOOPS[@]}"
    else
        mdadm --assemble "$MD" --uuid="$RAID_UUID" --run "${RAID_LOOPS[@]}"
    fi
    active_md=$(readlink -f "$MD")
elif [[ ! -e "$MD" ]]; then
    install -d -m 0755 /dev/md
    ln -s "../$(basename "$active_md")" "$MD"
fi
[[ $(md_uuid "$MD") == "$RAID_UUID" ]] || die 'Unexpected assembled RAID UUID.'
[[ $(cat "/sys/class/block/$(basename "$active_md")/md/level") == raid1 ]] || die 'Array is not RAID1.'
[[ $(cat "/sys/class/block/$(basename "$active_md")/md/raid_disks") == 2 ]] || die 'Array must contain two RAID devices.'
mapfile -t slaves < <(find "/sys/class/block/$(basename "$active_md")/slaves" -mindepth 1 -maxdepth 1 -printf '/dev/%f\n' | sort)
[[ $(printf '%s\n' "${slaves[@]}") == $(printf '%s\n' "${RAID_LOOPS[@]}" | sort) ]] || die 'Array includes unexpected devices.'

# A VG with the requested name must contain exactly our third loop device.
vg_exists=false
if vgs "$VG" 9>&- >/dev/null 2>&1; then
    vg_exists=true
    [[ $(pvs --noheadings -o pv_name --select "vg_name=$VG" 9>&- | trim) == "$PV" ]] || die "Foreign VG: $VG"
    [[ ,$(vgs --noheadings -o vg_tags "$VG" 9>&- | trim), == *",$TAG,"* ]] || die "VG ownership tag missing: $VG"
fi
pv_signature=$(signature "$PV")
if [[ -z $pv_signature ]]; then
    [[ ! -e "$LAB/pv.uuid" && $vg_exists == false ]] || die 'Existing PV metadata disappeared.'
    pvcreate --yes "$PV" 9>&-
    pvs --noheadings -o pv_uuid "$PV" 9>&- | trim > "$LAB/pv.uuid"
elif [[ $pv_signature != LVM2_member ]]; then
    die "Unexpected PV signature: $pv_signature"
fi
owned_file "$LAB/pv.uuid"
[[ -s "$LAB/pv.uuid" && $(pvs --noheadings -o pv_uuid "$PV" 9>&- | trim) == "$(cat "$LAB/pv.uuid")" ]] || die 'Foreign PV UUID.'
current_vg=$(pvs --noheadings -o vg_name "$PV" 9>&- | trim)
[[ -z $current_vg || $current_vg == "$VG" ]] || die "PV belongs to another VG: $current_vg"
if [[ $vg_exists == false ]]; then
    vgcreate --addtag "$TAG" "$VG" "$PV" 9>&-
fi
vgchange -ay "$VG" 9>&-
if ! lvs "$VG/$LV" 9>&- >/dev/null 2>&1; then
    lvcreate --yes --zero y -L 200M -n "$LV" --addtag "$TAG" "$VG" 9>&-
fi
[[ ,$(lvs --noheadings -o lv_tags "$VG/$LV" 9>&- | trim), == *",$TAG,"* ]] || die 'LV ownership tag missing.'
[[ $(blockdev --getsize64 "/dev/$VG/$LV") == $((200 * 1024 * 1024)) ]] || die 'Unexpected LV size.'

mount_ext4() {
    local device=$1 target=$2 filesystem source
    [[ ! -L "$target" ]] || die "Mountpoint must not be a symlink: $target"
    if [[ ! -d "$target" ]]; then install -d -m 0755 "$target"; fi
    if source=$(findmnt --noheadings --raw --mountpoint "$target" --output SOURCE); then
        [[ $(readlink -f "$source") == $(readlink -f "$device") ]] || die "Another filesystem is mounted on $target."
        [[ $(findmnt --noheadings --raw --mountpoint "$target" --output FSTYPE) == ext4 ]] || die "Unexpected filesystem on $target."
        return
    fi
    [[ -z $(find "$target" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "Refusing to hide existing files under $target."
    filesystem=$(signature "$device")
    if [[ -z $filesystem ]]; then
        mkfs.ext4 -q "$device"
    elif [[ $filesystem != ext4 ]]; then
        die "Unexpected filesystem on $device: $filesystem"
    fi
    mount -- "$device" "$target"
}

mount_ext4 "$MD" /mnt/raid
mount_ext4 "/dev/$VG/$LV" /mnt/logs
printf 'Storage ready: RAID1 at /mnt/raid; LVM at /mnt/logs.\n'
df -h /mnt/raid /mnt/logs
