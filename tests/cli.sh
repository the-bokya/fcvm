#!/usr/bin/env bash
# cli.sh — black-box tests of the command-line surface: help, dispatch, flag
# validation and the "missing artifact" guards. Runs fcvm as a subprocess with
# an empty throwaway BUILD_DIR so every artifact reads as absent.
# No network, no KVM.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EMPTY_BUILD="$(mktemp -d)"
at_exit "rm -rf '$EMPTY_BUILD'"

# run_fcvm <args...> — invoke fcvm against the empty build dir, capturing
# stdout+stderr into $OUT and the exit code into $RC.
run_fcvm() {
  OUT="$(BUILD_DIR="$EMPTY_BUILD" "$FCVM" "$@" 2>&1)"; RC=$?
}

# --- help / usage -----------------------------------------------------------
run_fcvm help
assert_eq       "help exits 0"        0 "$RC"
assert_contains "help shows usage"    "$OUT" "USAGE"
assert_contains "help lists commands" "$OUT" "setup"

run_fcvm
assert_eq       "no args -> help, exit 0" 0 "$RC"
assert_contains "no args shows usage"     "$OUT" "USAGE"

run_fcvm frobnicate
assert_eq       "unknown command exits 1" 1 "$RC"
assert_contains "unknown command shows usage" "$OUT" "fcvm"

# --- per-command flag validation --------------------------------------------
run_fcvm setup --bogus
assert_eq       "setup bad flag exits 1" 1 "$RC"
assert_contains "setup bad flag message" "$OUT" "unknown setup option"

run_fcvm build --bogus
assert_eq       "build bad flag exits 1" 1 "$RC"
assert_contains "build bad flag message" "$OUT" "unknown build option"

run_fcvm run --bogus
assert_eq       "run bad flag exits 1" 1 "$RC"
assert_contains "run bad flag message" "$OUT" "unknown run option"

run_fcvm up --bogus
assert_eq       "up bad flag exits 1" 1 "$RC"
assert_contains "up bad flag message" "$OUT" "unknown up option"

run_fcvm net sideways
assert_eq       "net bad action exits 1" 1 "$RC"
assert_contains "net usage message"      "$OUT" "fcvm net up|down"

# --- missing-artifact guards (empty build dir) ------------------------------
run_fcvm run --no-net
assert_eq       "run without firecracker exits 1" 1 "$RC"
assert_contains "run reports missing firecracker" "$OUT" "firecracker missing"

# --- read-only commands tolerate an empty build dir -------------------------
run_fcvm status
assert_eq       "status exits 0"            0 "$RC"
assert_contains "status shows firecracker"  "$OUT" "Firecracker"
assert_contains "status: firecracker absent" "$OUT" "not installed"

run_fcvm stop
assert_eq       "stop with no VM exits 0"  0 "$RC"
assert_contains "stop reports no VM"        "$OUT" "no VM running"
