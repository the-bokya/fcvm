# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-contained Bash project that boots **Alpine Linux** (default) or
**Ubuntu 24.04** microVMs on **Firecracker**, selected by the `DISTRO` env var.
Everything is driven by one executable script, `./fcvm`, plus
`config.env`. There is no build system, package manager, or test framework — it
is shell, KVM, and downloaded binaries.

## Commands

```sh
./fcvm setup            # download firecracker binary + guest kernel -> build/
./fcvm build            # build Alpine rootfs ext4 image (rootless)  -> build/alpine.ext4
./fcvm net up|down      # host tap fc-tap0 + NAT (the ONLY step needing sudo)
./fcvm run [--no-net]   # boot VM, attach serial console to this terminal
./fcvm ssh [cmd…]       # ssh root@<GUEST_IP>
./fcvm up               # setup + build + net up + run (one-shot)
./fcvm status           # what exists / network state
./fcvm clean [--all]    # remove rootfs+VM state; --all also drops downloads

bash -n fcvm            # syntax check after edits
```

**Smoke test (the closest thing to a test suite)** — boot the real rootfs
non-interactively and assert it reaches a root shell and powers off cleanly.
Input must be *delayed* past boot, because Firecracker wires the guest serial
console to stdin and anything sent before the login shell is ready is lost:

```sh
( sleep 16; printf 'id\ncat /etc/alpine-release\necho OK\npoweroff\n'; sleep 10 ) \
  | ./fcvm run --no-net 2>&1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -E 'uid=0|System halted'
```

After changing the rootfs builder, inspect the produced image *without booting*
using `debugfs` (read-only, no root):

```sh
debugfs -R 'cat /etc/inittab' build/alpine.ext4
debugfs -R 'cat /etc/shadow'  build/alpine.ext4 | grep '^root:'
```

## Architecture

Three concerns, each a `cmd_*` function in `fcvm`, all writing to `build/`:

1. **Acquire** (`cmd_setup`): the Firecracker release binary (auto-detected
   latest from GitHub unless `FC_VERSION` is pinned) and a **Firecracker "CI"
   guest kernel** — an uncompressed `vmlinux` from the `spec.ccfc.min` S3 bucket
   with every needed driver built in (virtio blk/net/mmio, ext4, devtmpfs
   auto-mount, `IP_PNP`, 8250 serial). This is deliberate: the guest *userland*
   is Alpine-latest, but the kernel is the microVM-tuned upstream one so no
   initramfs or kernel modules are ever required.

2. **Build rootfs** (`cmd_build` → `build_alpine` | `build_ubuntu`): the
   load-bearing trick. `DISTRO` (`alpine` default, or `ubuntu`) picks the
   builder; both produce `build/<distro>.ext4` **rootless** via the same shape:
   - *Phase 1* runs under a **persistent `fakeroot` session** (`-s state`) by
     re-invoking **this same script** (`fcvm __alpine_inside` / `__ubuntu_inside`)
     so all helper functions are in scope (see "Gotchas"). fakeroot makes the
     process look like root, so ownership/modes are recorded as `root:root`.
     - *Alpine*: `apk.static` (downloaded) installs a fresh Alpine system into
       `build/rootfs/` with `--usermode --initdb`.
     - *Ubuntu*: `unsquashfs` extracts Firecracker's official
       `ubuntu-24.04.squashfs` (downloaded, cached) into `build/rootfs/`.
   - *Phase 2*: a **real** `chmod -R u+rwX build/rootfs` (helper `pack_rootfs`)
     so the packer can read files left mode `0111` (e.g. Alpine's `bbsuid`).
     Touches real perms only; the faked metadata in the state file is untouched.
   - *Phase 3*: `fakeroot -i state mkfs.ext4 -d build/rootfs …` packs the tree,
     reloading the faked ownership so the image gets `root:root`. Alpine uses
     `ROOTFS_SIZE_MIB` directly; Ubuntu auto-sizes from actual usage + slack
     (floored at `ROOTFS_SIZE_MIB`).

   `configure_common` (shared) writes hostname/hosts/resolv.conf, the root
   password hash (host `openssl passwd -6`), and the SSH pubkey resolved by
   `cmd_build` — an explicit `SSH_PUBKEY`, else a dedicated `build/fcvm_id_ed25519`
   key-pair auto-generated on first build (`fcvm ssh` authenticates with the
   private half via `-i`). Then
   per-distro: *Alpine* writes a minimal `/etc/inittab` autologin
   (`/bin/login -f root`), OpenRC runlevel symlinks, fstab, and `PermitRootLogin`
   via sed; *Ubuntu* enables `ssh.service`, drops a `PermitRootLogin yes`
   snippet, and **rewrites the `serial-getty@ttyS0` override** to
   `agetty --autologin root` (see Gotchas).

3. **Boot** (`cmd_run`): writes `build/vm-config.json` and execs
   `firecracker --no-api --config-file …`. `--no-api` boots straight from the
   config (no REST socket dance) and connects the guest's serial port to this
   terminal. Guest networking is done entirely by the **kernel `ip=` cmdline**
   (`ip=GUEST::HOST:MASK::eth0:off`) — there is no in-guest DHCP/network
   service. The network NIC is only added if the host tap exists (or `--net`).
   An optional **data disk** (`DATA_DISK`) is created/formatted on the host by
   `ensure_data_disk` and attached as the second drive (`/dev/vdb`); rootfs stays
   first so it remains `/dev/vda`. It is raw by default; `DATA_DISK_FORMAT=true`
   ext4-formats it and `configure_common` adds an fstab entry so the guest
   auto-mounts it at `DATA_DISK_MOUNT`.

`cmd_net` is the only privileged piece: it creates a **persistent, user-owned**
tap (`ip tuntap … user $USER`) so the unprivileged Firecracker process can open
it, assigns the host `/30` address, and adds iptables MASQUERADE for guest
internet.

## Configuration

`config.env` is sourced by `fcvm`. Every variable uses the
`VAR="${VAR:-default}"` form so the environment overrides it — this matters
because Phase 1 re-sources `config.env` inside the fakeroot re-invocation, and
this form preserves values exported from the parent process.

## Gotchas / non-obvious constraints

- **`fcvm __alpine_inside` / `__ubuntu_inside` are internal.** Dispatched only
  from the fakeroot call in the builders; never call directly. They assume the
  env vars (`STAGING`, `APK_STATIC`/`SQUASHFS`, `REPO`, `PKGS`, …) the builder
  exports.
- **Ubuntu autologin requires `-f`.** Firecracker's Ubuntu image autologins with
  `agetty -o '-p -- \u'` (no `-f`), which only works while root has an *empty*
  password. We set a root password (for ssh), so `ubuntu_build_inside` must
  overwrite the `serial-getty@ttyS0` override to `agetty --autologin root`
  (without `-o`), which runs `login -f root` and never prompts. Don't reintroduce
  `-o`. (Alpine is unaffected: its inittab already uses `login -f root`.)
- **Data disk is formatted at most once, and the fstab entry is build-time.**
  `ensure_data_disk` (in `cmd_run`) only `mkfs`-es an *empty* image, so reboots
  never wipe data; turning `DATA_DISK_FORMAT` on for an already-raw image works
  only if `blkid` is available to confirm it's empty (else delete the image to
  reformat). The auto-mount fstab line is baked by `configure_common` at build
  time gated on `DATA_DISK_FORMAT`, so flipping the flag needs a rebuild to take
  effect in-guest. An unformatted disk is deliberately *not* in fstab. A
  `DATA_DISK` placed under `build/` is wiped by `clean --all`; put it elsewhere
  to persist.
- **fakeroot state must span the whole build.** Phase 1 and Phase 3 must use the
  same `-s`/`-i` state file, or the image loses `root:root` ownership.
- **`mkfs.ext4 -d` drops setuid/setgid bits.** Acceptable here because the guest
  runs everything as root, but don't rely on suid helpers (`su`, non-root
  `ping`) inside the guest.
- **Serial-console stdin races with boot.** Any automated `run` must delay input
  until after the login shell appears (see smoke test).
- **`--no-api` requires `--config-file`** and starts the VM immediately; there is
  no separate "start" call.
- **Expected harmless boot noise:** `fsck.ext4 not found`, `modprobe … can't
  change directory to '/lib/modules'`, `hwclock: Cannot access the Hardware
  Clock`. These come from a minimal, all-built-in-drivers microVM; do not try to
  "fix" them unless asked (add `e2fsprogs` to `ROOTFS_PACKAGES` to quiet fsck).
- **`build/` is disposable and git-ignored.** Treat it as a cache; `./fcvm
  clean --all` rebuilds everything from the network.

## Verified environment

Validated end-to-end on `x86_64` with KVM: Firecracker v1.16.0, kernel
`vmlinux-6.1.155`, Alpine `3.23.4` and Ubuntu `24.04.3 LTS` (systemd reports
`running`). The script auto-detects newer Firecracker
releases and (via `ALPINE_BRANCH=latest-stable`) newer Alpine releases; the
kernel is pinned by `FC_CI_VERSION`/`KERNEL_VERSION` in `config.env`.
