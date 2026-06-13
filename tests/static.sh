#!/usr/bin/env bash
# static.sh — static analysis: bash syntax + shellcheck. No network, no KVM.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- bash -n syntax checks --------------------------------------------------
assert_rc "fcvm parses (bash -n)"       0 bash -n "$FCVM"
assert_rc "config.env parses (bash -n)" 0 bash -n "$REPO_DIR/config.env"

# Every test file in this dir must itself be syntactically valid.
for f in "$TESTS_DIR"/*.sh; do
  assert_rc "$(basename "$f") parses (bash -n)" 0 bash -n "$f"
done

# --- shellcheck (gate when available, skip otherwise) -----------------------
# Severity is overridable; default to warning so genuine issues fail CI but
# pure style nits don't. SC1091 = "not following sourced file" (config.env is
# resolved at runtime, not statically), which is expected here.
sev="${SHELLCHECK_SEVERITY:-warning}"
if command -v shellcheck >/dev/null 2>&1; then
  for target in "$FCVM" "$TESTS_DIR"/*.sh; do
    name="$(basename "$target")"
    if out="$(shellcheck -S "$sev" -e SC1091 "$target" 2>&1)"; then
      _pass "shellcheck $name (severity=$sev)"
    else
      _fail "shellcheck $name (severity=$sev)" "$out"
    fi
  done
else
  skip "shellcheck" "shellcheck not installed"
fi
