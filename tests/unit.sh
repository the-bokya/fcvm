#!/usr/bin/env bash
# unit.sh — white-box tests of pure functions, by *sourcing* fcvm (its dispatch
# is guarded so sourcing defines functions without running anything).
# No network, no KVM.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Source the script under test, then drop the strict modes it sets at the top
# so failing assertions don't abort this test file.
# shellcheck source=/dev/null
source "$FCVM"
set +e +u +o pipefail

# --- mask2cidr: dotted-quad netmask -> CIDR prefix length -------------------
assert_eq "mask2cidr /30" 30 "$(mask2cidr 255.255.255.252)"
assert_eq "mask2cidr /32" 32 "$(mask2cidr 255.255.255.255)"
assert_eq "mask2cidr /24" 24 "$(mask2cidr 255.255.255.0)"
assert_eq "mask2cidr /25" 25 "$(mask2cidr 255.255.255.128)"
assert_eq "mask2cidr /20" 20 "$(mask2cidr 255.255.240.0)"
assert_eq "mask2cidr /16" 16 "$(mask2cidr 255.255.0.0)"
assert_eq "mask2cidr /8"   8 "$(mask2cidr 255.0.0.0)"
assert_eq "mask2cidr /0"   0 "$(mask2cidr 0.0.0.0)"

# --- is_true: boolean-ish parser --------------------------------------------
for v in 1 true yes on y TRUE Yes ON Y; do
  assert_rc "is_true accepts '$v'" 0 is_true "$v"
done
for v in 0 false no off n "" garbage 2; do
  assert_rc "is_true rejects '$v'" 1 is_true "$v"
done

# --- vm_pid: reports a live, tracked VM process -----------------------------
FC_PID="$(mktemp)"
: > "$FC_PID"
assert_rc "vm_pid: empty pidfile -> not running" 1 vm_pid

echo 999999999 > "$FC_PID"   # a pid that cannot be alive
assert_rc "vm_pid: dead pid -> not running"      1 vm_pid

echo "$$" > "$FC_PID"        # this very shell is certainly alive
assert_rc "vm_pid: live pid -> running"          0 vm_pid
assert_eq "vm_pid: prints the pid" "$$" "$(vm_pid)"
rm -f "$FC_PID"

FC_PID="/nonexistent/path/pidfile"
assert_rc "vm_pid: missing pidfile -> not running" 1 vm_pid

# --- defaults set at source time --------------------------------------------
assert_eq "DISTRO defaults to alpine" alpine "$DISTRO"
assert_contains "ROOTFS path is per-distro" "$ROOTFS" "alpine.ext4"

# --- configure_common: guest config written into the staging tree -----------
# Exercises real logic (hostname/hosts/resolv.conf, root password hash, ssh key
# injection, optional data-disk fstab) without any network or boot.
work="$(mktemp -d)"
(
  cd "$work" || exit 1
  mkdir -p etc
  printf 'root:!:19000:0:::::\nnobody:!:19000:0:::::\n' > etc/shadow

  GUEST_HOSTNAME="testbox" GUEST_DNS="9.9.9.9" ROOT_PASSWORD="s3cret" \
  SSH_PUBKEY="" MOUNT_DATA_DISK="no" DATA_DISK_MOUNT="/mnt/data" \
    configure_common >/dev/null 2>&1
)
assert_eq       "configure_common: hostname"      "testbox"           "$(cat "$work/etc/hostname")"
assert_contains "configure_common: resolv.conf"   "$(cat "$work/etc/resolv.conf")" "nameserver 9.9.9.9"
assert_contains "configure_common: hosts has host" "$(cat "$work/etc/hosts")" "testbox"
# Root password replaced with a real $6$ (sha-512) crypt hash, not left "!".
root_shadow="$(grep '^root:' "$work/etc/shadow")"
assert_contains "configure_common: root pw hashed" "$root_shadow" '$6$'
# No SSH_PUBKEY -> no authorized_keys created.
if [ -f "$work/root/.ssh/authorized_keys" ]; then
  _fail "configure_common: no key -> no authorized_keys" "file unexpectedly created"
else
  _pass "configure_common: no key -> no authorized_keys"
fi
rm -rf "$work"

# Same, but with a public key + data-disk auto-mount enabled.
work="$(mktemp -d)"
(
  cd "$work" || exit 1
  mkdir -p etc
  printf 'root:!:19000:0:::::\n' > etc/shadow
  echo "ssh-ed25519 AAAAFAKEKEY fcvm@test" > pub.key

  GUEST_HOSTNAME="testbox" GUEST_DNS="1.1.1.1" ROOT_PASSWORD="x" \
  SSH_PUBKEY="$work/pub.key" MOUNT_DATA_DISK="yes" DATA_DISK_MOUNT="/mnt/data" \
    configure_common >/dev/null 2>&1
)
assert_contains "configure_common: key injected" \
  "$(cat "$work/root/.ssh/authorized_keys" 2>/dev/null)" "ssh-ed25519 AAAAFAKEKEY"
assert_contains "configure_common: --mount fstab line" \
  "$(cat "$work/etc/fstab" 2>/dev/null)" "/dev/vdb"
assert_contains "configure_common: --mount mountpoint" \
  "$(cat "$work/etc/fstab" 2>/dev/null)" "/mnt/data"
rm -rf "$work"
