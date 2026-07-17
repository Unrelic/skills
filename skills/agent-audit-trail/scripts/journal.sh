#!/bin/bash
# =============================================================================
# journal.sh — append-only audit trail for delegated agent/subagent runs.
#
#   journal.sh --class <mechanical|standard|research|adversarial|synthesis>
#              --model <name> --effort <low|medium|high|default>
#              --label <text> --outcome <pass|fail|escalated|pending>
#              [--escalated-to <model:effort>] [--tokens <N>]
#              [--session <id>] [--notes <text>]
#              [--predict <text>] [--predict-failure <text>]
#              [--prediction-held <yes|no|partial>]
#              [--tool-uses <N>] [--duration-s <N>]
#
# One validated JSON Lines record per call, appended to
#   ${AGENT_AUDIT_DIR:-$HOME/.agent-audit}/journal.jsonl
# Closed vocabularies, fail-closed: any validation failure exits 2 with NO
# write. An escalation or a corrected outcome is a SECOND record, never a
# rewrite — this script has no update/delete operation, on purpose. No model
# call, no network. bash-3.2-safe (no associative arrays, no [[ ]]-only
# syntax that older bash lacks).
#
# --- prediction-before-data ---------------------------------------------------
# `--predict` / `--predict-failure` are OPTIONAL, ADDITIVE fields: a one-line
# expected deliverable and a one-line "what failure looks like", bound at
# DISPATCH time (typically the record carries outcome=pending at that point).
# `--prediction-held` grades a prediction AFTER the fact — it rides the SAME
# record as the terminal outcome (pass/fail/escalated), because this journal
# has no update/rewrite mechanic: like an escalation, a graded outcome is
# just another append, never a patch to the dispatch-time record. Two
# records for one spawn (dispatch with --predict, completion with
# --prediction-held) are joined by the caller's own --label/--session
# convention — this script does not invent a new linking mechanic.
# Mechanical-class spawns may predict tersely or skip entirely.
#
# --- instant-return tripwire (mechanical catch for a zero-tool-use fast
# "pass" with instruction-shaped output, no actual work behind it) -----------
# `--tool-uses <N>` / `--duration-s <N>` are OPTIONAL, ADDITIVE integer
# fields (exactly like `--tokens`): non-negative integers, absent by
# default, never required.
#
# Prompt wording is NOT the control here — this is a deterministic gate on
# caller-supplied counts, same shape as every other check in this script.
# When journaling a COMPLETION record (`--outcome pass`) for a NON-mechanical
# class, the tripwire FORCES `outcome=fail` and `prediction_held=no`, stamps
# a `tripwire` field naming the reason, and warns on stderr — it forces, it
# does not merely advise. The record IS still written (append-only: a forced
# verdict is a real event, never silently dropped). Firing rule:
#   - BOTH fields present: fires when `--tool-uses` is 0 AND `--duration-s`
#     is under the fast-return floor (`DURATION_FLOOR_S` below).
#   - `--duration-s` ABSENT but `--tool-uses` is 0: fires ONLY for
#     class=research. Zero tool calls is inherently suspicious for a
#     research spawn regardless of timing (it cannot have gathered
#     anything) — but a synthesis/adversarial spawn can legitimately reason
#     over context already in hand and finish with zero tool calls, so an
#     absent `--duration-s` does NOT fire alone for those classes.
# Does NOT fire: either field absent (back-compat), class=mechanical,
# outcome already fail/pending/escalated (this gate only inspects
# `--outcome pass`, by construction).
# =============================================================================
set -u

STATE_DIR="${AGENT_AUDIT_DIR:-$HOME/.agent-audit}"
JOURNAL="$STATE_DIR/journal.jsonl"
DURATION_FLOOR_S=15   # instant-return tripwire floor, seconds

usage() {
  cat >&2 <<'USAGE'
usage: journal.sh --class <mechanical|standard|research|adversarial|synthesis>
                   --model <name> --effort <low|medium|high|default>
                   --label <text> --outcome <pass|fail|escalated|pending>
                   [--escalated-to <model:effort>] [--tokens <N>]
                   [--session <id>] [--notes <text>]
                   [--predict <text>] [--predict-failure <text>]
                   [--prediction-held <yes|no|partial>]
                   [--tool-uses <N>] [--duration-s <N>]
USAGE
  exit 2
}
fail() { echo "journal: $1" >&2; exit 2; }

CLASS=""; MODEL=""; EFFORT=""; LABEL=""; OUTCOME=""
ESCTO=""; TOKENS=""; SESSION=""; NOTES=""
PREDICT=""; PREDICT_FAILURE=""; PREDICTION_HELD=""
TOOLUSES=""; DURATIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --class)            [ $# -ge 2 ] || usage; CLASS="$2"; shift 2 ;;
    --model)             [ $# -ge 2 ] || usage; MODEL="$2"; shift 2 ;;
    --effort)            [ $# -ge 2 ] || usage; EFFORT="$2"; shift 2 ;;
    --label)             [ $# -ge 2 ] || usage; LABEL="$2"; shift 2 ;;
    --outcome)           [ $# -ge 2 ] || usage; OUTCOME="$2"; shift 2 ;;
    --escalated-to)      [ $# -ge 2 ] || usage; ESCTO="$2"; shift 2 ;;
    --tokens)            [ $# -ge 2 ] || usage; TOKENS="$2"; shift 2 ;;
    --session)           [ $# -ge 2 ] || usage; SESSION="$2"; shift 2 ;;
    --notes)             [ $# -ge 2 ] || usage; NOTES="$2"; shift 2 ;;
    --predict)           [ $# -ge 2 ] || usage; PREDICT="$2"; shift 2 ;;
    --predict-failure)   [ $# -ge 2 ] || usage; PREDICT_FAILURE="$2"; shift 2 ;;
    --prediction-held)   [ $# -ge 2 ] || usage; PREDICTION_HELD="$2"; shift 2 ;;
    --tool-uses)         [ $# -ge 2 ] || usage; TOOLUSES="$2"; shift 2 ;;
    --duration-s)        [ $# -ge 2 ] || usage; DURATIONS="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *)                   usage ;;   # unrecognized flag (e.g. an edit/overwrite
                                     # attempt) is rejected here — there is no
                                     # rewrite path to fall into.
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"

# --- closed vocabularies, fail closed ------------------------------------------
case "$CLASS" in
  mechanical|standard|research|adversarial|synthesis) ;;
  "") usage ;;
  *) fail "bad --class '$CLASS' (closed vocab)" ;;
esac
case "$EFFORT" in
  low|medium|high|default) ;;
  "") usage ;;
  *) fail "bad --effort '$EFFORT' (closed vocab)" ;;
esac
case "$OUTCOME" in
  pass|fail|escalated|pending) ;;
  "") usage ;;
  *) fail "bad --outcome '$OUTCOME' (closed vocab)" ;;
esac
[ -n "$MODEL" ] || usage
[ -n "$LABEL" ] || usage
if [ -n "$TOKENS" ]; then
  printf '%s' "$TOKENS" | grep -qE '^[0-9]+$' || fail "--tokens must be a non-negative integer"
fi
if [ -n "$TOOLUSES" ]; then
  printf '%s' "$TOOLUSES" | grep -qE '^[0-9]+$' || fail "--tool-uses must be a non-negative integer"
fi
if [ -n "$DURATIONS" ]; then
  printf '%s' "$DURATIONS" | grep -qE '^[0-9]+$' || fail "--duration-s must be a non-negative integer"
fi
if [ "$OUTCOME" = "escalated" ] && [ -z "$ESCTO" ]; then
  fail "outcome=escalated requires --escalated-to <model:effort> (the rescue is a second record)"
fi
if [ -n "$ESCTO" ] && [ "$OUTCOME" != "escalated" ]; then
  fail "--escalated-to only valid with --outcome escalated"
fi
# --- prediction-held only makes sense once an outcome is known ---------------
if [ -n "$PREDICTION_HELD" ]; then
  case "$PREDICTION_HELD" in
    yes|no|partial) ;;
    *) fail "bad --prediction-held '$PREDICTION_HELD' (closed vocab: yes|no|partial)" ;;
  esac
  case "$OUTCOME" in
    pass|fail|escalated) ;;
    *) fail "--prediction-held only valid with --outcome pass|fail|escalated (grade after the outcome is known, never on pending)" ;;
  esac
fi

# --- instant-return tripwire: mechanical catch for a zero-tool-use, fast,
# instruction-shaped "pass" (see header for the full firing rule). Runs after
# all field validation above so TOOLUSES/DURATIONS are already known to be
# non-negative integers when compared here. Forces, does not advise.
TRIPWIRE=""
if [ "$OUTCOME" = "pass" ] && [ "$CLASS" != "mechanical" ] && [ -n "$TOOLUSES" ] && [ "$TOOLUSES" -eq 0 ]; then
  if [ -n "$DURATIONS" ] && [ "$DURATIONS" -lt "$DURATION_FLOOR_S" ]; then
    TRIPWIRE="zero-tool-use fast-return: tool_uses=0 duration_s=$DURATIONS < floor ${DURATION_FLOOR_S}s (forced from outcome=pass)"
  elif [ -z "$DURATIONS" ] && [ "$CLASS" = "research" ]; then
    TRIPWIRE="zero-tool-use research spawn: tool_uses=0, duration_s absent, class=research (forced from outcome=pass)"
  fi
fi
if [ -n "$TRIPWIRE" ]; then
  echo "journal: TRIPWIRE fired — forcing outcome=fail, prediction_held=no ($TRIPWIRE)" >&2
  OUTCOME="fail"
  PREDICTION_HELD="no"
fi

# --- append one record (single JSON line; jq encodes, so quotes/newlines are safe)
mkdir -p "$STATE_DIR" || fail "cannot create state dir $STATE_DIR"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LINE="$(jq -nc \
  --arg ts "$TS" --arg class "$CLASS" --arg model "$MODEL" --arg effort "$EFFORT" \
  --arg label "$LABEL" --arg outcome "$OUTCOME" --arg escalated_to "$ESCTO" \
  --arg tokens "$TOKENS" --arg session "$SESSION" --arg notes "$NOTES" \
  --arg predict "$PREDICT" --arg predict_failure "$PREDICT_FAILURE" \
  --arg prediction_held "$PREDICTION_HELD" \
  --arg tool_uses "$TOOLUSES" --arg duration_s "$DURATIONS" --arg tripwire "$TRIPWIRE" \
  '{ts:$ts, class:$class, model:$model, effort:$effort, label:$label, outcome:$outcome}
   + (if $escalated_to != "" then {escalated_to:$escalated_to} else {} end)
   + (if $tokens != "" then {tokens:($tokens|tonumber)} else {} end)
   + (if $session != "" then {session:$session} else {} end)
   + (if $notes != "" then {notes:$notes} else {} end)
   + (if $predict != "" then {predict:$predict} else {} end)
   + (if $predict_failure != "" then {predict_failure:$predict_failure} else {} end)
   + (if $prediction_held != "" then {prediction_held:$prediction_held} else {} end)
   + (if $tool_uses != "" then {tool_uses:($tool_uses|tonumber)} else {} end)
   + (if $duration_s != "" then {duration_s:($duration_s|tonumber)} else {} end)
   + (if $tripwire != "" then {tripwire:$tripwire} else {} end)')" || fail "record assembly failed"

printf '%s\n' "$LINE" >> "$JOURNAL" || fail "append failed: $JOURNAL"
echo "journaled: $CLASS $MODEL/$EFFORT -> $OUTCOME ($LABEL)"
exit 0
