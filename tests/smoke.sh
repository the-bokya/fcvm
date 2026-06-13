#!/usr/bin/env bash
# smoke.sh — the end-to-end test: download Firecracker + kernel, build the
# Alpine rootfs, boot the microVM and assert it reaches a root shell and exits
# cleanly. Input is *delayed* past boot because Firecracker wires the guest
# serial console to stdin and anything sent before the login shell is lost.
# Needs: /dev/kvm + network + fakeroot + mkfs.ext4 + curl.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- preconditions ----------------------------------------------------------
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  skip "microVM boot" "/dev/kvm not available/usable"; exit 0
fi
missing=""
for t in fakeroot mkfs.ext4 curl; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  skip "microVM boot" "missing tools:$missing"; exit 0
fi
if ! curl -fsI --max-time 15 https://dl-cdn.alpinelinux.org >/dev/null 2>&1; then
  skip "microVM boot" "no network"; exit 0
fi

BD="${FCVM_TEST_BUILD_DIR:-$(mktemp -d)}"
[ -n "${FCVM_TEST_BUILD_DIR:-}" ] || at_exit "rm -rf '$BD'"
export BUILD_DIR="$BD" ROOTFS_SIZE_MIB=256 MEM_MIB=512 VCPUS=1

# --- prepare artifacts (reuse if a shared build dir already has them) --------
printf '  .. fetching firecracker + kernel\n'
if ! out="$("$FCVM" setup 2>&1)"; then
  _fail "fcvm setup" "$(printf '%s\n' "$out" | tail -15)"; exit 1
fi
_pass "fcvm setup succeeds"

if [ ! -f "$BD/alpine.ext4" ]; then
  printf '  .. building alpine rootfs\n'
  if ! out="$("$FCVM" build 2>&1)"; then
    _fail "fcvm build" "$(printf '%s\n' "$out" | tail -15)"; exit 1
  fi
fi
_pass "rootfs ready"

# --- boot, drive a tiny script over the serial console, reboot --------------
# Clear any leftover detached VM from a previous run, and make sure we never
# leave one behind (e.g. if the boot times out before the guest reboots).
"$FCVM" stop >/dev/null 2>&1 || true
at_exit "BUILD_DIR='$BD' '$FCVM' stop >/dev/null 2>&1 || true"

printf '  .. booting microVM (no net)\n'
TOKEN="SMOKE_OK_$$"
log="$(mktemp)"; at_exit "rm -f '$log'"

# Delay input until the autologin shell is up (~16s), run a couple of commands,
# then reboot. We send `reboot` (not `poweroff`) on purpose: with `reboot=k` on
# the kernel cmdline, the guest reboot goes through the i8042 keyboard
# controller, which Firecracker handles by exiting cleanly — `poweroff` only
# halts the guest and leaves Firecracker running (the test would then hang until
# the timeout). The trailing sleep keeps stdin open while the guest reboots.
( sleep 16; printf 'id\necho %s\nreboot\n' "$TOKEN"; sleep 8 ) \
  | timeout 120 "$FCVM" run --no-net --console > "$log" 2>&1
rc=${PIPESTATUS[1]}

out="$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log")"

if [ "$rc" = 124 ]; then
  _fail "microVM exited (not timed out)" "boot/reboot exceeded 120s; last log lines:
$(printf '%s\n' "$out" | tail -20)"
else
  _pass "microVM exited cleanly (rc=$rc, not a timeout)"
fi
assert_contains "guest reached root shell (uid=0)" "$out" "uid=0"
assert_contains "guest ran our command ($TOKEN)"   "$out" "$TOKEN"
