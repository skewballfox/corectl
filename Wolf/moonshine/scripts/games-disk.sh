#!/bin/bash
# Sets up a games disk for Steam and mounts it, now and at boot, with mount
# options picked for its filesystem and the kind of disk it's on.
#
# Usage (as root): games-disk.sh <name> <device> [existing library]
# <name> is the library's directory under /var/mnt/games. <device> is any
# path to the filesystem (/dev/sdc1, /dev/disk/by-label/...); the units use
# its UUID, which doesn't change when disks are renumbered.
# [existing library] is a directory holding steamapps/, relative to the top
# of the filesystem. It's used in place and given to the service user;
# without it, a `steam` directory (a subvolume on btrfs) is created.
# Re-running is safe, and rewrites the units with the current options.
#
# Two mount units: the whole filesystem at /var/mnt/games-disks/<name>
# (root-only), and the library bound from there to /var/mnt/games/<name>,
# which Steam and moonshine bind. Only the library reaches the containers,
# whatever else is on the disk.
set -euo pipefail

die() { echo "$*" >&2; exit 1; }

name=$1
device=$2
lib=${3:-steam}

# Everything is checked before anything changes: a wrong device here means
# chowning and remounting someone else's data.
[[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "name must be letters, digits, - or _: $name"
[[ $lib != /* && /$lib/ != */../* ]] || die "library must be relative and stay on the disk: $lib"
# seinfo exits 0 for a missing type, so the count is checked
[ "$(seinfo -t moonshine_games_t | awk '/^Types:/{print $2}')" = 1 ] \
    || die "moonshine_games_t isn't loaded: run just moonshine setup-selinux first"

dev=$(realpath -e "$device") || die "$device doesn't exist"
[ -b "$dev" ] || die "$device isn't a block device"
devtype=$(lsblk -ndo TYPE "$dev")
case $devtype in
    part | crypt | lvm | raid*) ;;
    # A whole disk only when the filesystem is on it directly (nvme0n1 with
    # no partition table): with partitions, one of them was meant
    disk) [ "$(lsblk -nro NAME "$dev" | wc -l)" = 1 ] || die "$device is partitioned: give the partition" ;;
    *) die "$device is a $devtype device, not a disk, partition or volume" ;;
esac
# Held by LUKS, LVM or md: the filesystem, if any, is on the device above it
holders=$(find "/sys/class/block/${dev##*/}/holders" -mindepth 1 -printf '%f ')
[ -z "$holders" ] || die "$device is in use by $holders"
grep -q "^$dev " /proc/swaps && die "$device is in use as swap"

fstype=$(blkid -s TYPE -o value "$dev") || die "no filesystem on $device"
uuid=$(blkid -s UUID -o value "$dev")
[ -n "$uuid" ] || die "$device's filesystem has no UUID"

base=/var/mnt/games-disks/$name
where=/var/mnt/games/$name
# Mounted anywhere but this script's own two mounts (a re-run) means in use:
# the system disk, a desktop's library, a second setup under another name
others=$(findmnt -rn -o TARGET --source "UUID=$uuid" | grep -vxF -e "$base" -e "$where" | tr "\n" " " || true)
[ -z "$others" ] || die "$device is mounted at: $others"
# The name already set up for another disk or library
for pair in "$base=/dev/disk/by-uuid/$uuid" "$where=$base/$lib"; do
    unit=/etc/systemd/system/$(systemd-escape --path --suffix=mount "${pair%%=*}")
    [ ! -e "$unit" ] || grep -qxF "What=${pair#*=}" "$unit" \
        || die "$unit mounts something else: remove it, or pick another name"
done
findmnt -rn "$where" > /dev/null && [ ! -e "/etc/systemd/system/$(systemd-escape --path --suffix=mount "$where")" ] \
    && die "$where is already mounted, not by this script"

# Disk kind. lsblk reports a partition's (or LUKS/LVM volume's) rotational
# flag from the disk under it; the transport only shows on the disk itself,
# so it's taken from the bottom of the stack (-s lists it last).
if [ "$(lsblk -ndo ROTA "$dev")" = 1 ]; then
    kind=hdd
elif lsblk -nso TRAN "$dev" | grep -qw nvme; then
    kind=nvme
else
    kind=ssd
fi
discard=$(lsblk -ndrbo DISC-MAX "$dev")

# The label every file on the disk gets (moonshine.te): writable for the
# Steam container, read-only for moonshine. Mounting with context= also
# leaves the disk's own labels alone.
context=system_u:object_r:moonshine_games_t:s0

# noatime everywhere: loading a game reads thousands of files, and recording
# each read is a write for nothing (and on btrfs, copy-on-write metadata).
# Proton's prefixes need a POSIX filesystem (symlinks, ownership, case), so
# FAT, exFAT and NTFS are refused.
opts=noatime,context=$context
case $fstype in
    btrfs)
        # Compression costs CPU on reads and saves disk time. A hard disk is
        # the bottleneck, so it compresses harder; a SATA SSD (~550 MB/s) is
        # still slower than zstd:1 decompression. NVMe outruns decompression
        # on the cores the game and the stream encoder are using, so it's
        # left uncompressed. Most game data is compressed already; btrfs's
        # heuristic skips what doesn't shrink.
        # autodefrag on the hard disk: game updates rewrite parts of big
        # files, which copy-on-write scatters across the platter.
        # discard=async (the kernel's default where supported, stated here):
        # batched trims, off the write path.
        opts+=,subvolid=5
        case $kind in
            hdd) opts+=,compress=zstd:3,autodefrag ;;
            ssd) opts+=,compress=zstd:1 ;;
            nvme) ;;
        esac
        [ "$kind" != hdd ] && [ "$discard" != 0 ] && opts+=,discard=async
        ;;
    ext4 | xfs)
        # No online discard (it trims inline with every delete, and Steam
        # deletes a lot during updates); fstrim.timer trims weekly instead.
        ;;
    *) die "$device is $fstype: Steam libraries need btrfs, ext4 or xfs" ;;
esac

# Writes a mount unit (its name must be the escaped path, or systemd refuses
# it), enables it and (re)mounts it, which also applies changed options.
# WantedBy, not RequiredBy local-fs.target: a missing disk doesn't fail the
# boot, and Steam shows its empty mountpoint as an unavailable library.
mount_unit() {
    local what=$1 where=$2 type=$3 options=$4 extra=${5:-} unit
    unit=$(systemd-escape --path --suffix=mount "$where")
    cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=Steam library $name (moonshine)
$extra
[Mount]
What=$what
Where=$where
Type=$type
Options=$options

[Install]
WantedBy=multi-user.target
EOF
    # Root's umask here is 027; systemd warns about unreadable unit files
    chmod 0644 "/etc/systemd/system/$unit"
    systemctl daemon-reload
    systemctl enable "$unit"
    systemctl restart "$unit"
}

install -d -m 0700 /var/mnt/games-disks "$base"
mount_unit "/dev/disk/by-uuid/$uuid" "$base" "$fstype" "$opts"

if [ ! -e "$base/$lib" ]; then
    [ "$lib" = steam ] || die "$lib isn't on $device"
    if [ "$fstype" = btrfs ]; then
        btrfs subvolume create "$base/steam"
    else
        mkdir "$base/steam"
    fi
fi
[ -d "$base/$lib" ] || die "$lib on $device isn't a directory"
# Only what isn't wolf's already: chown rewrites every inode it touches
# (copy-on-write on btrfs)
find "$base/$lib" \( ! -user wolf -o ! -group wolf \) -exec chown -h wolf:wolf {} +
chmod 0750 "$base/$lib"

# The mountpoint takes moonshine_games_t from moonshine.fc. On a re-run the
# library is mounted over it, so it's unmounted first (mount_unit remounts it)
# or restorecon would reach the library instead.
mkdir -p "$where"
! mountpoint -q "$where" || systemctl stop "$(systemd-escape --path --suffix=mount "$where")"
restorecon -F /var/mnt/games "$where"
# Requires the disk's unit: stopping or restarting it does the same to this
mount_unit "$base/$lib" "$where" none bind "RequiresMountsFor=$base"

[ "$fstype" = btrfs ] || [ "$kind" = hdd ] || systemctl enable --now fstrim.timer

echo "$name: $fstype on $kind" >&2
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS "$base"
findmnt -o TARGET,SOURCE "$where"
