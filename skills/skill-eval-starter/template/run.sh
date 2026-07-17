#!/usr/bin/env bash
# run.sh — the hermetic eval battery runner (skill-eval-starter starter template).
#
# Runs every case under cases/*/case.json against its known-good expected property,
# writes results.json, and exits nonzero if any case regressed. No model calls, no
# network — every scorer here is grep, diff, or a script's exit code. That's the
# point: this file has to be able to fail the build, or it isn't a gate.
#
# Usage:
#   bash run.sh              # run the battery, write results.json
#   bash run.sh --baseline   # also overwrite baseline.json with this run's results
#                             # (the new floor to beat — only do this deliberately)
#
# Portable: POSIX + bash 3.2 safe (no associative arrays, no mapfile). Requires jq.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TALLY="$(mktemp)"; trap 'rm -f "$TALLY"' EXIT

HELD="$(jq -r '.held_out[]?' "$ROOT/split.json" 2>/dev/null || true)"
is_held(){ printf '%s\n' "$HELD" | grep -qx "$1"; }

pass=0; fail=0; ho_pass=0; ho_fail=0; FAILS=""

for cj in "$ROOT"/cases/*/case.json; do
  [ -f "$cj" ] || continue
  dir="$(dirname "$cj")"
  id="$(basename "$dir")"
  cat="$(jq -r '.category' "$cj")"
  typ="$(jq -r '.run.type' "$cj")"
  exp_v="$(jq -r '.expect.verdict' "$cj")"
  exp_x="$(jq -r '.expect.exit // "0"' "$cj")"

  case "$typ" in
    grep-absent)
      # Mechanical lint: a forbidden pattern must NOT appear in the fixture file.
      f="$dir/$(jq -r '.run.file' "$cj")"; pat="$(jq -r '.run.pattern' "$cj")"
      if grep -Eq "$pat" "$f" 2>/dev/null; then got_v="FAIL"; xc=1; else got_v="OK"; xc=0; fi ;;
    grep-present)
      # Mechanical lint: a required pattern must appear in the fixture file.
      f="$dir/$(jq -r '.run.file' "$cj")"; pat="$(jq -r '.run.pattern' "$cj")"
      if grep -Eq "$pat" "$f" 2>/dev/null; then got_v="OK"; xc=0; else got_v="FAIL"; xc=1; fi ;;
    script)
      # Escape hatch for anything grep can't express (diff, custom parsing, etc.).
      # The script must live in-repo, be deterministic, and take the case directory
      # as its only argument. It prints "OK ..." or "FAIL ..." on stdout and sets
      # its exit code accordingly — the runner reads only the first word + exit code.
      s="$ROOT/$(jq -r '.run.script' "$cj")"
      out="$(bash "$s" "$dir" 2>/dev/null)"; xc=$?
      got_v="${out%% *}" ;;
    *)
      got_v="ERR"; xc=99 ;;
  esac

  if [ "$got_v" = "$exp_v" ] && [ "$xc" = "$exp_x" ]; then
    pass=$((pass+1)); printf '%s pass\n' "$cat" >> "$TALLY"
    is_held "$id" && ho_pass=$((ho_pass+1)) || true
  else
    fail=$((fail+1)); printf '%s fail\n' "$cat" >> "$TALLY"
    is_held "$id" && ho_fail=$((ho_fail+1)) || true
    FAILS="$FAILS
  FAIL $cat/$id: got ${got_v}(exit ${xc}) want ${exp_v}(exit ${exp_x})"
  fi
done

total=$((pass+fail)); score="0.000"; [ "$total" -gt 0 ] && score="$(awk "BEGIN{printf \"%.3f\", $pass/$total}")"
ho_total=$((ho_pass+ho_fail)); ho_score="1.000"; [ "$ho_total" -gt 0 ] && ho_score="$(awk "BEGIN{printf \"%.3f\", $ho_pass/$ho_total}")"
bycat="$(awk '{t[$1]++; if($2=="pass")p[$1]++} END{first=1; for(c in t){if(!first)printf ","; first=0; printf "\n    \"%s\": {\"pass\": %d, \"total\": %d}", c, p[c]+0, t[c]}}' "$TALLY")"

printf '{\n  "overall": {"pass": %d, "fail": %d, "total": %d, "score": %s},\n  "held_out": {"pass": %d, "fail": %d, "total": %d, "score": %s},\n  "by_category": {%s\n  }\n}\n' \
  "$pass" "$fail" "$total" "$score" "$ho_pass" "$ho_fail" "$ho_total" "$ho_score" "$bycat" > "$ROOT/results.json"

echo "-- eval battery --"
echo "overall: $pass/$total ($score) . held-out: $ho_pass/$ho_total ($ho_score)"
[ -n "$FAILS" ] && printf '%s\n' "$FAILS"

if [ "${1:-}" = "--baseline" ]; then
  cp "$ROOT/results.json" "$ROOT/baseline.json"
  echo "baseline.json written (the floor to beat)."
fi

[ "$fail" -eq 0 ]
