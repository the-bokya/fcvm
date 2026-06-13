#!/usr/bin/env bash
# tests/lib.sh — minimal pure-bash assertion helpers (no external deps).
#
# Source this at the top of every test file. It tracks pass/fail/skip counts
# and, on exit, prints a one-line human summary and (if FCVM_RESULT_FILE is set,
# which run.sh does) writes "<pass> <fail> <skip>" there so the runner can
# aggregate across files. A test file exits non-zero iff any assertion failed.

# Locations, derived from this file so tests work from any cwd.
# (Consumed by the test files that source this one.)
# shellcheck disable=SC2034
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FCVM="$REPO_DIR/fcvm"

_PASS=0; _FAIL=0; _SKIP=0

if [ -t 1 ]; then _g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _b=$'\033[1m'; _z=$'\033[0m'
else _g=; _r=; _y=; _b=; _z=; fi

_pass() { _PASS=$((_PASS + 1)); printf '  %sok%s   %s\n' "$_g" "$_z" "$1"; }
_fail() {
  _FAIL=$((_FAIL + 1)); printf '  %sFAIL%s %s\n' "$_r" "$_z" "$1"
  [ $# -gt 1 ] && printf '         %s\n' "$2"
  return 0
}
# skip <name> [reason] — record a skipped check (e.g. missing tool / no KVM).
skip() {
  _SKIP=$((_SKIP + 1)); printf '  %sskip%s %s\n' "$_y" "$_z" "$1"
  [ $# -gt 1 ] && printf '         (%s)\n' "$2"
  return 0
}

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "expected [$2], got [$3]"; fi
}
# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1" "[$2] does not contain [$3]" ;; esac
}
# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  case "$2" in *"$3"*) _fail "$1" "[$2] unexpectedly contains [$3]" ;; *) _pass "$1" ;; esac
}
# assert_rc <name> <expected_rc> <cmd...> — run cmd (output discarded), check rc.
assert_rc() {
  local name="$1" want="$2"; shift 2
  local rc=0; "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then _pass "$name"; else _fail "$name" "expected rc=$want, got rc=$rc"; fi
}
# assert_file <name> <path>
assert_file() {
  if [ -f "$2" ]; then _pass "$1"; else _fail "$1" "missing file: $2"; fi
}

# at_exit <cmd...> — register a cleanup command run when the test file exits
# (use this instead of `trap ... EXIT`, which would clobber the summary trap).
_CLEANUP=()
at_exit() { _CLEANUP+=("$*"); }

_summary() {
  local c
  for c in "${_CLEANUP[@]:-}"; do [ -n "$c" ] && eval "$c"; done
  printf '%s----%s %d passed, %d failed, %d skipped\n' "$_b" "$_z" "$_PASS" "$_FAIL" "$_SKIP"
  [ -n "${FCVM_RESULT_FILE:-}" ] && printf '%d %d %d\n' "$_PASS" "$_FAIL" "$_SKIP" > "$FCVM_RESULT_FILE"
  [ "$_FAIL" -eq 0 ] || exit 1
}
trap _summary EXIT
