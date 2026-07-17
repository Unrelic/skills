---
name: agent-audit-trail
description: Design and maintain an append-only audit trail for every agent or subagent run a system delegates work to — what got logged, in what shape, and how outcomes get verified instead of self-reported. Use when a user asks how to log, track, or audit what an AI agent or subagent actually did; when they want to detect an agent silently returning a fake "pass" without doing the work (a zero-tool-use instant return); when they're designing a multi-agent or orchestrator system and need a record of every delegated spawn (model used, task class, outcome); when they ask how to verify an agent's self-reported success instead of trusting it at face value; when they want to bind a prediction before a task runs so the outcome can be graded against something instead of judged in hindsight; or when they're building an escalation or model-routing table and need real failure-rate data instead of a guess. Trigger phrases include "audit trail for agents", "log every subagent spawn", "track what my agents actually did", "the agent said it passed but I can't verify that", "detect a fake pass", "journal for delegated tasks", "escalation tracking", "prediction before the agent runs", "stop agents from grading their own homework".
---

# Agent Audit Trail

Teaches an agent (any agent, any orchestrator, any stack) how to build a record of
what actually happened when work was delegated to another agent or subagent run —
not what that run *said* happened. A delegated agent's own summary of its work is
not evidence; it's a claim. This skill is about the structural record that lets you
check the claim later, and the mechanical checks that catch the cases where the
claim and the reality diverge.

The pattern generalizes past any specific tool: one append-only record per
delegated run, written to a structured log, validated against closed vocabularies
before it's ever written, with corrections and predictions layered on as
*additional* records rather than edits to history.

## The core record

Every delegated run — a subagent spawn, a worker invocation, a background job
handed to another model — gets exactly one append-only record at completion,
written as a single line of JSON (JSON Lines: one record per line, append-only,
trivially greppable and diffable). At minimum, a record carries:

```json
{"ts":"2026-07-16T14:02:11Z","class":"standard","model":"model-b","effort":"medium","label":"parse-refactor-pr-142","outcome":"pass"}
```

- **`class`** — the task's verification reach (see below), not its topic.
- **`model` / `effort`** — what actually ran, so the log can later answer "did the
  cheap tier hold up" without anyone remembering.
- **`label`** — a short, greppable description tying the record to the actual work
  (a ticket id, a PR number, a task name) — human-readable, not free-form prose.
- **`outcome`** — `pass`, `fail`, `escalated`, or `pending`. Nothing else.

A log with unbounded free-text fields and no schema is not an audit trail — it's a
diary, and diaries don't support the mechanical checks this skill is built around.

## Closed vocabularies, fail closed

Every field with a fixed meaning (`class`, `effort`, `outcome`, and any other
enum-shaped field you add) is validated against a closed list *before* anything is
written. A value outside that list is a hard failure — the record is not written
at all, and the caller gets a nonzero exit and an error naming the bad field.

A reasonable starting vocabulary for `class`, sized by verification reach rather
than topic:

| class | what verifies it |
|---|---|
| `mechanical` | deterministic checks — tests, compiles, digests, grep-provable work |
| `standard` | testable output — implementation with tests, structured extraction |
| `research` | cited gathering that a caller cross-checks afterward |
| `adversarial` | judgment work — security review, refutation, red-teaming |
| `synthesis` | judgment work — architecture verdicts, integration, human-facing conclusions |

Fail closed matters more here than almost anywhere else in a logging system: a
half-written or best-guess record is worse than a missing one, because it *looks*
like data. A missing record is an obvious gap; a malformed one silently corrupts
every aggregate built on top of the log (escalation rates, pass rates, per-class
fitness numbers — see below). Reject at the door, every time, with no "just this
once" path for a value that doesn't fit the schema.

## Corrections are a second record, never a rewrite

The log has no update or delete operation. None. If a spawn that was journaled as
`pending` later resolves, that resolution is a **new** record, not an edit to the
old one. If a spawn fails and gets escalated to a stronger model, the escalation
is a **second** record (`outcome=escalated`, plus which model/effort it escalated
to) alongside the original failure record — the rescue does not erase the fact
that the first attempt failed. Two records for one logical unit of work are joined
by the caller's own convention (a shared `label`, a shared `session` id) — the log
format itself doesn't need a special linking mechanic, because append-only *is*
the mechanic.

This is the property that makes the log trustworthy enough to build a fitness
number on top of. A log that can be edited after the fact is a log that can be
quietly cleaned up after a bad run — which means every aggregate computed from it
is only as honest as whoever had write access that day. An append-only log can't
be cleaned up; the failure is still sitting there in the file next to the record
that fixed it, which is exactly what you want when you're trying to measure how
often a class of task actually needs rescuing.

## Bind a prediction before you have the data

An outcome recorded with no prediction bound before the work ran is a bullseye
drawn around a bullet hole — it proves *something happened*, not that the routing
or delegation choice that led to it was any good. Close that gap by binding a
one-line prediction at **dispatch** time, before the delegated run starts:

- A one-line expected deliverable (`predict`) and a one-line description of what
  failure would look like (`predict_failure`). One line each — a prediction, not a
  spec. If the prediction is detailed enough to constrain *how* the delegated
  agent does the work, it's over-specified; the test is whether the agent could
  still surprise you and still be judged correctly against the prediction.
- Mechanical-class work can predict tersely or skip the prediction entirely — the
  same "don't turn this into ceremony" logic that keeps the whole system usable
  applies to the prediction contract itself.

Grade the prediction — `prediction_held: yes | no | partial` — only once the
outcome is known, and because the log has no rewrite mechanic, the grade rides the
**same terminal record** as the outcome (the `pass`/`fail`/`escalated` record), not
a patch to the dispatch-time record. This mirrors escalation: a graded outcome is
just another append, never an edit to what was written at dispatch.

With predictions bound and graded, an escalation table stops being a raw tally and
becomes a learnable signal: a class with both a high escalation rate *and*
consistently `prediction_held: no` is a routing bug with evidence attached, not a
hunch that the cheap tier "feels" unreliable.

## Deterministic tripwires on caller-supplied counts

The most damaging failure this log has to catch is not a wrong answer — it's a
delegated run that does *nothing* and reports success anyway. A subagent that
returns in a few seconds with zero tool calls and confident, instruction-shaped
output has not done the work; it has produced text that looks like a completed
task. Left alone, that record says `outcome: pass`, and every downstream number
built on the log is now wrong in a way nobody will notice until much later.

Catch this mechanically, not by reading the output more carefully:

- Require the caller to supply `tool_uses` (an integer count) and, ideally,
  `duration_s` alongside the outcome.
- If the caller claims `outcome: pass` on a non-mechanical class, and
  `tool_uses == 0`, and either `duration_s` is under a fast-return floor (a
  reasonable default is 15 seconds) or `duration_s` is absent on a `research`-class
  task (zero tool calls is inherently disqualifying for research — it cannot have
  gathered anything), the validator **forces** `outcome: fail` and
  `prediction_held: no`, stamps a `tripwire` field naming which rule fired, and
  warns loudly on stderr. It forces the correction; it does not merely flag it for
  someone to notice later.
- The record is still written — forcing the verdict is not the same as dropping
  the record. An append-only log records the forced correction as a real event,
  the same way it records anything else.

**Prompt wording is never the control here.** This check does not read the label,
the notes, or the agent's own claim of what it did — it compares caller-supplied
integers against a fixed floor. That's the entire point: the failure mode this
catches is exactly the case where the *wording* is convincing and the actual work
is absent. A control that trusted wording would be defeated by the same failure it
exists to catch.

## Escalation rate is the fitness number

Once every routed spawn is journaled, the per-class escalation rate — the
fraction of a class's spawns that end in `outcome: escalated` — becomes the
number that tells you whether your routing choices are actually working, instead
of a policy you set once and never revisit:

- A class sitting well above a chosen threshold means the routing table is wrong
  for that class: propose a change and bring the journal data as the evidence.
- Watch for silent *over*-escalation too. A system that routes everything to the
  strongest tier "to be safe" will show a low escalation rate for exactly the
  wrong reason — nothing is failing because nothing cheap is ever attempted. Pair
  the escalation rate with the class distribution itself (what fraction of spawns
  are even attempted at the cheap tier) to catch this.
- A spawn that isn't journaled is a spawn the routing table can't learn from.
  Journaling every routed spawn — not just the interesting ones — is what makes
  the escalation rate a real measurement instead of a survivorship-biased one.

## What this prevents

- **Silent quality drift.** Without a comparable record over time, a slow decline
  in a delegated agent's output quality looks like nothing at all — there's no
  baseline to drift away from. The log is what makes "compared to last month" a
  question you can actually answer.
- **Unverifiable "the agent said it passed."** A self-report with no structural
  check behind it is not verification, no matter how confident or detailed the
  report reads. The tripwire above exists specifically because confident wording
  and actual completed work are independent facts.
- **Self-graded theater.** The same run that did the work rating its own work as
  good, with no independent signal anywhere in the loop, is a closed circuit —
  it can only confirm itself. Binding a prediction *before* the outcome is known,
  and grading it against caller-supplied counts rather than the agent's own
  narrative, breaks that circuit.

## Refusals

- **Refuse to accept a claimed `pass` that fails the tripwire check.** A
  well-written label or notes field does not override a caller-supplied
  `tool_uses`/`duration_s` pair that fails the floor. Force the correction
  mechanically; don't let prose talk the validator out of it.
- **Refuse to edit or delete a past record to "fix" it.** There is no operation
  in this system for that. If a record was wrong, append a correction that says
  so; the old record stays exactly as it was written.
- **Refuse to fabricate a count the caller didn't supply.** If `tool_uses` or
  `duration_s` wasn't provided, leave the field absent — don't estimate or infer
  a plausible-looking number. A fabricated count is worse than a missing one: a
  missing field is an honest gap; a guessed field silently poisons the tripwire
  logic and every aggregate downstream of it.
- **Refuse to grade a prediction before the outcome is known.** `prediction_held`
  only attaches to a terminal outcome record (`pass`/`fail`/`escalated`), never to
  a `pending` one — grading something that hasn't happened yet isn't grading, it's
  guessing with extra steps.

## Anti-patterns

- **Rewrite-as-correction.** Editing a past record in place instead of appending a
  new one. The moment the log supports an update operation, every aggregate built
  on it becomes only as trustworthy as whoever had write access — the entire value
  of append-only evaporates the first time someone "cleans up" an inconvenient
  entry.
- **Self-graded pass.** Treating the delegated agent's own summary as sufficient
  evidence of `outcome: pass`, with no caller-supplied count (tool uses, duration,
  anything structural) checked against it. Confidence in the writing and
  correctness of the work are unrelated facts.
- **Prediction-free outcome.** Recording an outcome with no prediction bound at
  dispatch, then reasoning backward from what happened to construct a story about
  why it was expected. That's not calibration, it's hindsight wearing
  calibration's clothes.
- **Prompt-wording-as-control.** Building the tripwire (or any safety check in
  this log) as a check on the *text* the agent produced — a keyword scan, a
  sentiment check, an "does this sound complete" heuristic — rather than a check
  on caller-supplied structural counts. Text is exactly what an instant, empty
  return can fake convincingly; integers describing what actually happened are
  much harder to fake by accident.
- **Unlogged spawn.** Treating journaling as optional for routine or "obviously
  fine" spawns. The escalation rate and every other aggregate this log supports
  is only honest if the denominator includes everything, not just the spawns
  someone remembered to log.

## Reference implementation

`scripts/journal.sh` is a portable (bash 3.2-safe), dependency-light (`jq` only)
reference implementation of the pattern above: closed-vocabulary validation,
fail-closed on any bad field, the zero-tool-use tripwire, and prediction binding
and grading. It's a starting point to adapt to your own stack, not a required
dependency — the pattern is what this skill teaches; the script is one way to
enforce it mechanically. See `evals/mechanical/run.sh` for runnable checks against
it (rewrite rejection, tripwire firing, fail-closed validation).
