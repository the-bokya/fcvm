# fcvm — Alpine Linux microVMs on Firecracker

A single script (`./fcvm`) that takes you from nothing to a booted, login-ready
[Firecracker](https://github.com/firecracker-microvm/firecracker) microVM
running either **Alpine Linux** (default) or **Ubuntu 24.04**. It downloads
Firecracker and a microVM kernel, builds the guest root filesystem **without
needing root**, and boots it under KVM.

```
./fcvm up                  # Alpine: download + build + network + boot
DISTRO=ubuntu ./fcvm up    # the same, for Ubuntu 24.04
```

You land on an autologin root console inside the guest in well under a second of
boot time. The two distros use the same kernel and tooling; pick one with the
`DISTRO` variable (the rootfs images coexist under `build/`).

## Requirements

- Linux host with **KVM** enabled — `/dev/kvm` must exist and be read/writable
  by you (e.g. you are in the `kvm` group).
- `x86_64` (the default kernel is x86_64; see *Other architectures* below).
- Tools on the host: `bash`, `curl`, `fakeroot`, `mkfs.ext4` (e2fsprogs),
  `ip` (iproute2). Plus `tar` for Alpine, or `unsquashfs` (squashfs-tools) for
  Ubuntu. Optional: `openssl` (to set the guest root password), `iptables` (to
  give the guest internet), `ssh` (for `./fcvm ssh`).
- `sudo` — **only** for `./fcvm net up/down` (creating the host tap device and
  NAT). Downloading, building the rootfs, and booting need **no root**.

Nothing is installed system-wide: every artifact lands in `./build/`.

## Quick start

```sh
# One-shot (prompts for sudo password once, for the tap device):
./fcvm up

# Or step by step:
./fcvm setup        # fetch firecracker binary + guest kernel  -> build/
./fcvm build        # build the Alpine rootfs ext4 image       -> build/alpine.ext4
./fcvm net up       # create tap fc-tap0 + NAT (sudo)
./fcvm run          # boot and attach to the serial console
```

Inside the guest you are logged in as `root` automatically. Type `poweroff` to
shut the VM down (that returns you to your shell). From another terminal you can
also reach it over SSH:

```sh
./fcvm ssh                 # ssh root@172.16.0.2 (password: "alpine", or your key)
./fcvm ssh apk add htop    # run a command and return
```

## Choosing the guest distro

`DISTRO` selects the guest (default `alpine`). Set it on any command — it must
be consistent across `build`/`run` for a given VM:

```sh
DISTRO=ubuntu ./fcvm up            # Ubuntu 24.04, one-shot
# or step by step:
DISTRO=ubuntu ./fcvm build
DISTRO=ubuntu ./fcvm run
```

| | `alpine` (default) | `ubuntu` |
|---|---|---|
| Source | Built from scratch with `apk.static` (Alpine `latest-stable`) | Firecracker's official `ubuntu-24.04.squashfs`, converted to ext4 |
| Init | OpenRC | systemd |
| Size | ~80 MiB used | ~400 MiB used |
| Image | `build/alpine.ext4` | `build/ubuntu.ext4` |

Both autologin as root on the serial console, ship `sshd`, use the same
Firecracker kernel, and honor `GUEST_HOSTNAME` / `ROOT_PASSWORD` / `SSH_PUBKEY`.
Set `DISTRO=ubuntu` permanently in `config.env` if you prefer.

## Commands

| Command | What it does |
|---|---|
| `./fcvm setup` | Download the Firecracker binary and the guest kernel into `build/`. |
| `./fcvm build` | Build the Alpine rootfs `build/alpine.ext4` (rootless). |
| `./fcvm net up` / `down` | Create/destroy host tap `fc-tap0` + NAT. Uses `sudo`. |
| `./fcvm run [--no-net]` | Boot the VM and attach its serial console to your terminal. |
| `./fcvm ssh [cmd…]` | SSH into the running guest as root. |
| `./fcvm up` | `setup` + `build` + `net up` + `run`. |
| `./fcvm status` | Show what exists and whether the network is up. |
| `./fcvm clean [--all]` | Remove the rootfs/VM state; `--all` also removes downloads. |

`./fcvm run` enables networking automatically **if** the tap device exists;
otherwise it boots without a NIC. Force either way with `--net` / `--no-net`.

## Testing

A pure-bash test suite lives in [`tests/`](./tests) — no framework, just shell:

```sh
./tests/run.sh            # fast tiers: static + unit + cli (no network, no KVM)
./tests/run.sh all        # also build (network) + smoke (boots a real microVM)
./tests/run.sh build      # run a single tier
```

| Tier | Needs | What it checks |
|---|---|---|
| `static` | — (shellcheck optional) | `bash -n` syntax + `shellcheck` on the suite |
| `unit` | — | pure functions, by *sourcing* `fcvm` (`mask2cidr`, `is_true`, `vm_pid`, `configure_common`) |
| `cli` | — | help/usage, flag validation, missing-artifact guards (black-box) |
| `build` | network + `fakeroot` + `debugfs` | builds the Alpine rootfs and inspects the ext4 image read-only |
| `smoke` | `/dev/kvm` + network | boots the microVM, asserts it reaches a root shell and exits cleanly |

The same tiers run on every push/PR via GitHub Actions
([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)). The heavy tiers
honor `FCVM_TEST_BUILD_DIR` (a reusable build dir) and shrink the image via
`ROOTFS_SIZE_MIB` to stay fast.

## Configuration

All knobs live in [`config.env`](./config.env) and can be overridden per-run via
the environment:

```sh
MEM_MIB=2048 VCPUS=4 ./fcvm run                 # bigger VM
ROOTFS_PACKAGES="util-linux htop curl" ./fcvm build   # extra guest packages
ALPINE_BRANCH=v3.23 ./fcvm build                # pin Alpine to a release series
```

Common settings: `VCPUS`, `MEM_MIB`, `ROOTFS_SIZE_MIB`, `ROOTFS_PACKAGES`,
`ROOT_PASSWORD`, `SSH_PUBKEY`, `GUEST_HOSTNAME`, and the networking block
(`TAP_DEV`, `HOST_IP`, `GUEST_IP`, …).

## Networking model

A point-to-point `/30` link between host and guest:

```
host  fc-tap0  172.16.0.1  <--->  172.16.0.2  eth0  guest
                         (NAT via your default uplink → internet)
```

The guest address is assigned by the **kernel** at boot via the `ip=` cmdline —
no in-guest DHCP client or network service is required. `./fcvm net up` also
adds iptables MASQUERADE so the guest can reach the internet through your
machine's default interface.

## How it works (one paragraph)

`setup` fetches the upstream Firecracker release binary and a Firecracker
"CI" guest kernel — an uncompressed `vmlinux` with all virtio drivers built in,
so no initramfs or modules are needed. `build` produces the rootfs under
**`fakeroot`** so it stays `root:root`-owned and then packs it with
`mkfs.ext4 -d` — all without `sudo`: for Alpine it installs a fresh system with
`apk.static`; for Ubuntu it `unsquashfs`-es Firecracker's official image and
tweaks it. `run` writes a
Firecracker JSON config and boots with `firecracker --no-api --config-file …`,
wiring the guest's serial port to your terminal. See [`CLAUDE.md`](./CLAUDE.md)
for the detailed architecture.

## Other architectures

The default kernel is `x86_64`. On `aarch64`, override the kernel version to one
that exists in the bucket and the script handles the console/cmdline
differences:

```sh
KERNEL_VERSION=6.1.155 ./fcvm setup    # pick an aarch64 vmlinux that exists
```

(Browse `https://s3.amazonaws.com/spec.ccfc.min/?prefix=firecracker-ci/` for the
available kernels per architecture.)

## Troubleshooting

- **`/dev/kvm` permission denied** — add yourself to the `kvm` group
  (`sudo usermod -aG kvm $USER`) and re-login, or check `ls -l /dev/kvm`.
- **Guest has no internet** — ensure `iptables` is installed and run
  `./fcvm net up`; check `sysctl net.ipv4.ip_forward` is `1`.
- **Cosmetic boot messages** (`fsck.ext4 not found`, `modprobe … /lib/modules`,
  `hwclock: Cannot access the Hardware Clock`) are expected on a minimal
  built-in-driver microVM and are harmless.
- **Stale tap after a crash** — `./fcvm net down` then `./fcvm net up`.
