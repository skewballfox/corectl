#!/bin/bash
# Adds a games disk's library to Steam's libraryfolders.vdf in the Steam home
# volume. Big Picture's Add Drive doesn't list the bind-mounted libraries and
# has no folder picker, and its "Switch to Desktop" hangs (Steam thinks it's in
# a gamescope session with a desktop to switch to), so the entry is written
# here instead.
#
# Usage (as root): steam-library.sh <name> <steam dir>
# <name> is the library under /var/mnt/games (games-disk.sh); <steam dir> is
# Steam's install in the volume, as the host sees it. Re-running is safe: a
# library already listed is left alone.
set -euo pipefail

die() { echo "$*" >&2; exit 1; }

name=$1
steam=$2
# Paths as the Steam container sees them (moonshine-launch-steam.sh)
path=/mnt/games/$name
root=/home/retro/.local/share/Steam

[[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "name must be letters, digits, - or _: $name"
mountpoint -q "/var/mnt/games/$name" || die "/var/mnt/games/$name isn't mounted: run games-disk.sh first"
# runuser keeps the working directory, which wolf may not be able to enter
cd /

vdf=$steam/steamapps/libraryfolders.vdf
grep -qE "^\s*\"path\"\s+\"$path\"\s*\$" "$vdf" 2> /dev/null && { echo "$path is already a Steam library" >&2; exit 0; }

# Before the install exists, Steam's bootstrap would find a half-made one
[ -e "$steam/steam.sh" ] || die "Steam isn't installed in its volume yet: start it once (just moonshine update-steam), then rerun"
# Steam rewrites the file from memory when it exits, dropping the entry
running=$(runuser -u wolf -- env XDG_RUNTIME_DIR="/run/user/$(id -u wolf)" podman ps -q --filter name=^moonshine-steam\$) \
    || die "can't ask podman whether Steam is running"
[ -z "$running" ] || die "Steam is running and would overwrite the change: stop it (just moonshine stop), then rerun"

# One library's entry. Steam names each library by a random 64-bit contentid
# (also in the library's own libraryfolder.vdf, which Steam writes).
entry() {
    printf '\t"%s"\n\t{\n' "$1"
    printf '\t\t"%s"\t\t"%s"\n' path "$2" label "$3" \
        contentid "$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')" \
        totalsize 0 update_clean_bytes_tally 0 time_last_update_verified 0
    printf '\t\t"apps"\n\t\t{\n\t\t}\n\t}\n'
}

runuser -u wolf -- mkdir -p "$steam/steamapps"
new=$(mktemp "$vdf.XXXXXX")
trap 'rm -f "$new"' EXIT
if [ -e "$vdf" ]; then
    # Libraries are the top level's numbered keys; the next is one past the last
    index=$(awk -F'"' '/^\t"[0-9]+"$/ { n = $2 + 1 } END { print n + 0 }' "$vdf")
    # Before the closing brace of "libraryfolders", the file's last line
    awk -v entry="$(entry "$index" "$path" "$name")" '
        prev != "" { print prev }
        { prev = $0 }
        END {
            if (prev != "}") { print "libraryfolders.vdf doesn'\''t end in }" > "/dev/stderr"; exit 1 }
            print entry; print prev
        }' "$vdf" > "$new"
    cp -a "$vdf" "$vdf.bak"
else
    # Steam writes the file on its first library change; without its own
    # install listed as "0", that one would go missing
    { printf '"libraryfolders"\n{\n'; entry 0 "$root" ""; entry 1 "$path" "$name"; printf '}\n'; } > "$new"
fi
chown wolf:wolf "$new"
chmod 0644 "$new"
# The volume's label, which a file root makes here wouldn't get
chcon --reference="$steam/steamapps" "$new"
mv "$new" "$vdf"
trap - EXIT
echo "$path added to Steam's libraries" >&2
