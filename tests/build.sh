#!/usr/bin/env bash
# build.sh — build a real Alpine rootfs (rootless, via fakeroot) and inspect the
# resulting ext4 image with debugfs, without ever booting it.
# Needs: network (Alpine mirror) + fakeroot + mkfs.ext4 + debugfs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- preconditions ----------------------------------------------------------
missing=""
for t in fakeroot mkfs.ext4 debugfs curl; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  skip "alpine build" "missing tools:$missing"; exit 0
fi
if ! curl -fsI --max-time 15 https://dl-cdn.alpinelinux.org >/dev/null 2>&1; then
  skip "alpine build" "no network to Alpine mirror"; exit 0
fi

# Build into a throwaway dir (or a caller-provided one, e.g. CI cache), with a
# small rootfs so mkfs/packing stays fast.
BD="${FCVM_TEST_BUILD_DIR:-$(mktemp -d)}"
[ -n "${FCVM_TEST_BUILD_DIR:-}" ] || at_exit "rm -rf '$BD'"
export BUILD_DIR="$BD" ROOTFS_SIZE_MIB=256
IMG="$BD/alpine.ext4"

# --- build ------------------------------------------------------------------
printf '  .. building alpine rootfs into %s\n' "$BD"
if ! out="$("$FCVM" build 2>&1)"; then
  _fail "fcvm build (alpine)" "$(printf '%s\n' "$out" | tail -15)"
  exit 1   # nothing else to inspect
fi
_pass "fcvm build (alpine) succeeds"
assert_file "alpine.ext4 produced" "$IMG"

# Auto-generated ssh key-pair lands on the host.
assert_file "ssh private key generated" "$BD/fcvm_id_ed25519"
assert_file "ssh public key generated"  "$BD/fcvm_id_ed25519.pub"

# --- inspect the image read-only with debugfs (no boot, no root) ------------
dbfs() { debugfs -R "cat $1" "$IMG" 2>/dev/null; }

assert_contains "image: /etc/alpine-release present" "$(dbfs /etc/alpine-release)" "."
assert_contains "image: inittab autologin root"      "$(dbfs /etc/inittab)" "login -f root"
assert_eq       "image: hostname baked"   "fcvm" "$(dbfs /etc/hostname)"
assert_contains "image: root password hashed" "$(dbfs /etc/shadow | grep '^root:')" '$6$'
assert_contains "image: PermitRootLogin yes"  "$(dbfs /etc/ssh/sshd_config)" "PermitRootLogin yes"
assert_contains "image: ssh key injected"     "$(dbfs /root/.ssh/authorized_keys)" "ssh-ed25519"
assert_contains "image: rootfs fstab (/dev/vda)" "$(dbfs /etc/fstab)" "/dev/vda"
# Without --mount there must be no data-disk auto-mount line.
assert_not_contains "image: no /dev/vdb without --mount" "$(dbfs /etc/fstab)" "/dev/vdb"

# --- rebuild with --mount: data-disk auto-mount baked into fstab ------------
printf '  .. rebuilding with --mount\n'
if ! out="$("$FCVM" build --mount 2>&1)"; then
  _fail "fcvm build --mount" "$(printf '%s\n' "$out" | tail -15)"
else
  _pass "fcvm build --mount succeeds"
  assert_contains "image: --mount adds /dev/vdb fstab line" "$(dbfs /etc/fstab)" "/dev/vdb"
fi
