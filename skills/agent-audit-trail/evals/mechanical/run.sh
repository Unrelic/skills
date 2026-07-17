#!/bin/bash
# =============================================================================
# run.sh — runnable mechanical checks for scripts/journal.sh.
#
# These are NOT LLM-judged evals (that's evals/evals.json, which checks
# whether the skill triggers and what an agent following it recommends).
# These are deterministic assertions against the bundled reference
# implementation itself: given a seeded journal fixture, does the validator
# actually reject a rewrite, actually force a fake pass to fail, and
# actually refuse to write on a closed-vocabulary violation.
#
# Usage: bash evals/mechanical/run.sh
# Exits 0 if all cases pass, 1 if any case fails. Requires bash and jq.
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JOURNAL_SH="$HERE/../../scripts/journal.sh"
FIXTURE="$HERE/fixtures/seed.jsonl"

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required" >&2; exit 1; }
[ -x "$JOURNAL_SH" ] || chmod +x "$JOURNAL_SH" 2>/dev/null

FAILED=0
pass_case() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1"; FAILED=1; }

# --- shared setup: a fresh temp state dir seeded from the fixture -----------
setup_tmp() {
  TMPDIR_CASE="$(mktemp -d)"
  cp "$FIXTURE" "$TMPDIR_CASE/journal.jsonl"
  export AGENT_AUDIT_DIR="$TMPDIR_CASE"
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# =============================================================================
# Case 1: rewrite rejection.
# An "edit" flag has no meaning to this validator — there is no update/rewrite
# operation, on purpose. Any attempt to invoke one falls through to the usage
# handler and exits 2 with the journal file byte-for-byte unchanged.
# =============================================================================
setup_tmp
BEFORE_HASH="$(hash_file "$AGENT_AUDIT_DIR/journal.jsonl")"
BEFORE_LINES="$(wc -l < "$AGENT_AUDIT_DIR/journal.jsonl" | tr -d ' ')"

"$JOURNAL_SH" --rewrite-record 1 --outcome pass >/tmp/journal-case1.out 2>&1
CASE1_EXIT=$?

AFTER_HASH="$(hash_file "$AGENT_AUDIT_DIR/journal.jsonl")"
AFTER_LINES="$(wc -l < "$AGENT_AUDIT_DIR/journal.jsonl" | tr -d ' ')"

if [ "$CASE1_EXIT" -eq 2 ] && [ "$BEFORE_HASH" = "$AFTER_HASH" ] && [ "$BEFORE_LINES" = "$AFTER_LINES" ]; then
  pass_case "rewrite attempt (--rewrite-record) rejected: exit=2, journal file unchanged (2 lines, hash stable)"
else
  fail_case "rewrite attempt should exit 2 with an unchanged journal (got exit=$CASE1_EXIT, before_lines=$BEFORE_LINES after_lines=$AFTER_LINES, hash_stable=$([ "$BEFORE_HASH" = "$AFTER_HASH" ] && echo yes || echo no))"
fi

# =============================================================================
# Case 2: instant-return tripwire forces a claimed pass to fail.
# tool_uses=0 and duration_s=4 (under the 15s floor) on a non-mechanical
# class must force outcome=fail regardless of the claimed --outcome pass,
# and must stamp a tripwire field on the record that IS still written.
# =============================================================================
setup_tmp
BEFORE_LINES="$(wc -l < "$AGENT_AUDIT_DIR/journal.jsonl" | tr -d ' ')"

"$JOURNAL_SH" --class standard --model test-model --effort medium \
  --label "suspicious-instant-return" --outcome pass \
  --tool-uses 0 --duration-s 4 >/tmp/journal-case2.out 2>&1
CASE2_EXIT=$?

AFTER_LINES="$(wc -l < "$AGENT_AUDIT_DIR/journal.jsonl" | tr -d ' ')"
LAST_RECORD="$(tail -n 1 "$AGENT_AUDIT_DIR/journal.jsonl")"
LAST_OUTCOME="$(printf '%s' "$LAST_RECORD" | jq -r '.outcome')"
HAS_TRIPWIRE="$(printf '%s' "$LAST_RECORD" | jq 'has("tripwire")')"
STDERR_WARNED="$(grep -c "TRIPWIRE fired" /tmp/journal-case2.out || true)"

if [ "$CASE2_EXIT" -eq 0 ] \
   && [ "$AFTER_LINES" -eq $((BEFORE_LINES + 1)) ] \
   && [ "$LAST_OUTCOME" = "fail" ] \
   && [ "$HAS_TRIPWIRE" = "true" ] \
   && [ "$STDERR_WARNED" -ge 1 ]; then
  pass_case "zero-tool-use fast return (tool_uses=0, duration_s=4) forced outcome=fail with a tripwire field, record still written"
else
  fail_case "tripwire should force outcome=fail + write a tripwire field (got exit=$CASE2_EXIT outcome=$LAST_OUTCOME has_tripwire=$HAS_TRIPWIRE stderr_warned=$STDERR_WARNED)"
fi

# =============================================================================
# Case 3: closed-vocabulary violation fails closed — no partial write.
# An unrecognized --class value must exit nonzero and leave the journal file
# completely unchanged (not even a malformed line appended).
# =============================================================================
setup_tmp
BEFORE_HASH="$(hash_file "$AGENT_AUDIT_DIR/journal.jsonl")"
BEFORE_LINES="$(wc -l < "$AGENT_AUDIT_DIR/journal.jsonl" | tr -d ' ')"

"$JOURNAL_SH" --class banana --model test-model --effort medium \
  --label "bad-class-should-not-write" --outcome pass >/tmp/journal-case3.out 2>&1
CASE3_EXIT=$?

AFTER_HASH="$(hash_file "$AGENT_AUDIT_DIR/journal.jsonl")"
AFTER_LINES="$(wc -l < "$AGENT_AUDIT_DIR/journal.jsonl" | tr -d ' ')"

if [ "$CASE3_EXIT" -eq 2 ] && [ "$BEFORE_HASH" = "$AFTER_HASH" ] && [ "$BEFORE_LINES" = "$AFTER_LINES" ]; then
  pass_case "invalid --class 'banana' rejected: exit=2, journal file unchanged (fail closed, no partial write)"
else
  fail_case "invalid --class should exit 2 with an unchanged journal (got exit=$CASE3_EXIT, hash_stable=$([ "$BEFORE_HASH" = "$AFTER_HASH" ] && echo yes || echo no))"
fi

echo "---"
if [ "$FAILED" -eq 0 ]; then
  echo "all mechanical cases passed"
  exit 0
else
  echo "one or more mechanical cases FAILED"
  exit 1
fi
