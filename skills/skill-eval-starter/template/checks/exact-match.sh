#!/usr/bin/env bash
# exact-match.sh — deterministic diff scorer, the `script` run type's example check.
#
# Usage: exact-match.sh <case-dir>
# Reads <case-dir>/expected.txt and <case-dir>/actual.txt, diffs them byte-for-byte,
# and reports the verdict. This is the shape any check script should follow: one
# argument (the case directory), stdout's first word is the verdict, the exit code
# backs it up. No model, no network, no randomness — swap the diff for whatever
# deterministic check your case actually needs.
set -uo pipefail
dir="${1:?usage: exact-match.sh <case-dir>}"

if diff -q "$dir/expected.txt" "$dir/actual.txt" >/dev/null 2>&1; then
  echo "OK actual.txt matches expected.txt exactly"
  exit 0
else
  echo "FAIL actual.txt differs from expected.txt"
  exit 1
fi
