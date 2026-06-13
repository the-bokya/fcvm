#!/usr/bin/env bash
# run.sh — run the fcvm test suite, in tiers.
#
#   tests/run.sh                  # fast tiers: static unit cli  (no net, no KVM)
#   tests/run.sh all              # every tier, incl. build (network) + smoke (KVM)
#   tests/run.sh static unit      # only the named tiers
#   tests/run.sh build smoke      # the heavy tiers on their own
#
# Each tier is a file tests/<tier>.sh. They run as separate processes; this
# runner streams their output live and aggregates pass/fail/skip via a per-file
# result file. Exits non-zero if any tier had a failure or failed to produce a
# result (crashed).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

FAST_TIERS=(static unit cli)
ALL_TIERS=(static unit cli build smoke)

case "${1:-}" in
  ""|fast|default) tiers=("${FAST_TIERS[@]}") ;;
  all)             tiers=("${ALL_TIERS[@]}") ;;
  *)               tiers=("$@") ;;
esac

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Z=$'\033[0m'; else B=; G=; R=; Z=; fi

tp=0; tf=0; ts=0; bad=0
for t in "${tiers[@]}"; do
  f="$t.sh"
  printf '\n%s== %s ==%s\n' "$B" "$t" "$Z"
  if [ ! -f "$f" ]; then
    printf '%s  no such tier: %s%s\n' "$R" "$t" "$Z"; bad=$((bad + 1)); continue
  fi
  rf="$(mktemp)"
  FCVM_RESULT_FILE="$rf" bash "$f"   # streams live; exit code mirrored by result file
  if [ -s "$rf" ]; then
    read -r p fl sk < "$rf"
    tp=$((tp + p)); tf=$((tf + fl)); ts=$((ts + sk))
    [ "$fl" -gt 0 ] && bad=$((bad + 1))
  else
    printf '%s  tier %s crashed (no result)%s\n' "$R" "$t" "$Z"; bad=$((bad + 1))
  fi
  rm -f "$rf"
done

printf '\n%s==== total: %d passed, %d failed, %d skipped ====%s\n' "$B" "$tp" "$tf" "$ts" "$Z"
if [ "$bad" -gt 0 ]; then
  printf '%sFAILED%s\n' "$R" "$Z"; exit 1
fi
printf '%sPASSED%s\n' "$G" "$Z"
