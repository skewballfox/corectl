# Testing rootless Wolf (minimal image)

Branch `wolf/rootless-minimal`. Runs Wolf from the fork's minimal image
(`skewballfox/wolf`, branch `docker/layered-minimal-image`, target
`runner-minimal`) as the image's unprivileged `wolf` user via `--rootless`:
no GOW root init, no gosu, no capabilities. Every step below needs privilege
escalation, so run them by hand from the repo root.

## What changed

- `common.just`: `build-and-sign` takes `-c/--context <dir>` (default `.`, so
  existing callers are unchanged).
- `Wolf/wolf.just`:
  - `build-wolf`: shallow-clones the fork branch, caps ninja at `-j3` (unbounded
    it OOM'd this 32G host; rootless buildah ignores `--memory`), builds and
    signs `gow/wolf:minimal`. `build-containers` now calls it.
  - `load-image` / `load-images`: copy the signed `dir:` output into the wolf
    user's storage. The system policy rejects `dir:`, so a scoped policy
    verifies the secure-build GPG signature on the way in; the signature is
    carried over so the `containers-storage` `signedBy` rule accepts it.
  - `setup-udev`: installs `85-wolf.rules` from the fork (`/dev/uinput` +
    `/dev/uhid` → group `wolf-input` (rewritten from upstream's `input`), which `wolf` is in; `/dev/uhid` is currently
    `root 0600`).
  - `install`: `/etc/wolf` is now `wolf:wolf` (was `root:wolf 0750`, which Wolf
    can't write its config/certs/app state into).
  - `setup` runs `setup-udev` and `load-images` too.
- `Wolf/wolf/wolf.container`:
  - `Image=localhost/gow/wolf:minimal`, `Exec=--rootless`.
  - `UserNS=keep-id:uid=990,gid=990`: container `wolf` (990) = host `wolf`, so
    `/etc/wolf` files and the podman socket line up.
  - `GroupAdd=keep-groups`: passes on the host user's render/wolf-input groups
    (they show up as `nogroup` inside, access still works).
  - NVIDIA via CDI (`AddDevice=nvidia.com/gpu=all`) instead of the device list +
    driver volume (its setup needs root). The volume is still passed to app
    containers through `NVIDIA_DRIVER_VOLUME_NAME`.
  - Socket is now `%t/podman/podman.sock` (the wolf user's own). The old
    `/run/podman/podman.sock` is the rootful one, unreachable (`/run/podman` is
    `root 0700`).
  - Removed `--device-cgroup-rule` (rootless podman refuses to start with it)
    and `--security-opt label=type:container_use_devices.process` (that type
    isn't in the loaded policy; crun fails on it).
  - `WOLF_RENDER_NODE=/dev/dri/renderD128` (the NVIDIA card here; was 129).

Already verified locally as an unprivileged user with the same flags: the
quadlet generates cleanly; Wolf runs as uid 990 with no caps, detects NVENC
(h264/h265/av1) with the zero-copy pipeline through CDI, talks to a rootless
podman socket, and files it writes in `/etc/wolf` are owned by the host user.
Not verified: anything needing the wolf user, uinput/uhid, a real stream.

## Steps

```bash
cd ~/Workspace/corectl   # on branch wolf/rootless-minimal

# 1. udev rules, then check: crw-rw---- root wolf-input for both
run0 just wolf::setup-udev
ls -l /dev/uinput /dev/uhid

# 2. build + sign (wolf compile takes a while; nvidia-driver image too).
#    Watch `free -g`: expect ~3.5G per compiler, 3 compilers. If it still
#    gets tight: run0 just wolf::build-wolf jobs=2
run0 just wolf::build-containers
#    or only the wolf image:
run0 just wolf::build-wolf

# 3. load into the wolf user's storage (verifies the signature)
run0 just wolf::load-images
run0 -u wolf env XDG_RUNTIME_DIR=/run/user/$(id -u wolf) podman images

# 4. install quadlets + chown /etc/wolf to wolf
run0 just wolf::install

# 5. start
run0 systemctl --user -M wolf@ start pulseaudio.service wolf.service
run0 journalctl _SYSTEMD_USER_UNIT=wolf.service -f
```

`just -n` prints `sudo` instead of `run0`: dry-run doesn't evaluate `shell()`,
so the OS detection falls back. Real runs use `run0`.

## What to check

In the wolf.service log:

- `Running Wolf rootless as wolf`
- `Using h264 encoder: nvcodec` and `Using zero copy pipeline on Nvidia`
- No `Permission denied` on `/etc/wolf`; `ls -ln /etc/wolf/cfg` shows the host
  wolf uid (992), with `config.toml`, `cert.pem` and `key.pem`.
- PulseAudio: no `[PULSE] Unable to connect` and no `Starting PulseAudio docker
  container` (that means the shared socket didn't work and it fell back to the
  sidecar). The PA container runs in a different user namespace, so this relies
  on the volume dir being world-searchable and the socket 0777.

Then pair a Moonlight client and stream:

- [ ] Desktop/app starts: `run0 -u wolf env XDG_RUNTIME_DIR=/run/user/$(id -u wolf) podman ps`
- [ ] Video + audio
- [ ] Mouse/keyboard (compositor, no device needed)
- [ ] Gamepad (uinput) and a DualSense (uhid)
- [ ] App can write its home: `/etc/wolf/profile_data/...` is created by Wolf as
      host uid 992; the app container's init has to chown it for its own user
- [ ] Stop wolf.service: app containers are stopped and removed

## If something fails

- **uinput/uhid denied, `ausearch -m avc -ts recent` shows denials**: the
  container runs as plain `container_t` now. Options, narrowest first:
  generate a udica policy for the wolf container (what the old
  `container_use_devices.process` label looks like it was meant to be);
  `setsebool -P container_use_devices on` (all containers); or
  `SecurityLabelDisable=true` in wolf.container.
- **podman errors about `/var/lib/container-stores/wolf`**: `container_conf.toml`
  lists it under `additionalimagestores` but nothing creates it (the builder
  writes signed `dir:` copies to `/var/lib/secure-build/containers/wolf`). This
  is from before this branch; drop the entry or create the dir.
- **`cudanvrtc ... undefined symbol: nvrtcGetCUBINSize` warning**: the image's
  baked CUDA 11.0 nvrtc. CDI doesn't inject a host nvrtc, so the root path's fix
  wouldn't find one either. Not caused by `--rootless`.
- **`--rootless needs the container started as a non-root user`**: `UserNS=`
  wasn't applied; check the generated unit with
  `/usr/libexec/podman/quadlet -dryrun -user`.

## Rolling back

```bash
git switch main
run0 just wolf::install
run0 systemctl --user -M wolf@ restart wolf.service
```

`/etc/wolf` stays `wolf:wolf`; `run0 chown -R root:wolf /etc/wolf` to restore.
