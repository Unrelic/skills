---
name: skill-eval-starter
description: Bootstrap a hermetic eval battery for a Claude Skill so you can prove it works and prove it keeps working — cases as fixtures, deterministic scorers, a baseline file, a train/holdout split, and a run.sh that exits nonzero on any regression. Use when a user is about to publish or ship a skill and has no tests for it; when they ask "how do I test this skill", "add evals to my skill", "benchmark this skill", "how do I know this skill still works after I edited the prompt", or "prevent this skill from regressing"; when they want to prove a skill's claims with a rerunnable before/after benchmark instead of an assertion; or when they're deciding whether a green eval run actually means anything. Trigger phrases include "eval this skill", "test my skill", "skill regression", "eval battery", "starter template for skill evals".
---

# Skill Eval Starter

Teaches an agent how to give a Claude Skill a hermetic eval battery — the thing that
turns "I edited the prompt and it feels better" into a number you can defend. This is
not about grading prose with another model call. Model-graded scoring has a real place
— whether a skill *triggers* on an ambiguous prompt is inherently a judgment call, and
the usual convention for that is a separate `evals/evals.json` of `should_trigger` /
`expected_behaviors` cases reviewed by a human or a model. But the floor — did this
specific change break something that worked yesterday — has to be a program, not an
opinion, or the "eval battery" is just a vibe with extra steps.

## The thesis

A skill without evals is a vibe. It reads well, the author likes it, and nobody can say
whether last week's "improved" rewrite made it worse, because there is nothing to run.
Ship every skill with a hermetic eval battery built on five parts:

- **Cases as fixtures**, not prose. A case is input + an expected *property* of the
  output ("the verdict is OK", "the forbidden pattern is absent"), never an expected
  *string* to fuzzy-match against — string matching breaks on harmless rewording and
  hides real regressions inside "close enough" diffs.
- **Deterministic scorers.** grep, diff, exit code. No model call, no network, no
  randomness. A scorer that itself needs a model to grade its verdict is a second
  untested skill wearing a lab coat.
- **A baseline file.** `baseline.json` is the floor to beat, committed next to the skill.
  Regressions become a diff against a checked-in number, not a debate about whether the
  new version "feels" as good as the old one.
- **A train/holdout split.** Some cases you can look at and write prose against; some you
  never touch while iterating. If every case you wrote also shaped the words you wrote,
  you didn't measure the skill — you overfit your prose to your own test.
- **A `run.sh` that exits nonzero on any regression.** If it can't fail the build, it's
  documentation wearing a test's clothes, not a gate.

## The starter template

Copy `template/` into your own skill's directory, rename `cases/example-case/` (and
`cases/example-script-check/`) to your first real cases, and run it:

```
bash template/run.sh
```

It ships with two working example cases and exits 0 out of the box, so you can see a
green run before you've written anything of your own. `run.sh --baseline` writes
`baseline.json`; every later run diffs against it and fails the moment a case that used
to pass stops passing. `checks/` holds an example deterministic scorer script
(`exact-match.sh`, a `diff`-based check) demonstrating the escape hatch for the `script`
run type, alongside the built-in `grep-absent` / `grep-present` run types for mechanical
lints. `split.json` marks which case ids are held out from prose iteration versus which
are fair game while you're actively writing the skill. Rename, add cases, wire your own
check scripts — the runner doesn't care what property you're testing as long as the
check is a program with an exit code.

## The published-benchmark angle

A before/after eval table is the marketing asset. "We rewrote the retry logic and it's
better now" is a claim; "37/40 → 40/40 on the published battery, diff attached" is
evidence a stranger can rerun themselves. Publish `baseline.json` and the case count
next to the skill's README — a small, honest, rerunnable benchmark beats a large
unverifiable claim every time, the same way a company publishing "here's our benchmark
repo, go run it yourself" earns more trust than a blog post with no artifact behind it.
If you change the skill and the published score doesn't move, that's information too —
say so.

## What this prevents

- **Prompt drift.** Skills get "tightened" over months of small edits; nothing catches
  the one edit that quietly drops the clause that mattered. A battery does, because it
  runs the same cases against every version.
- **Regressive "improvements."** A rewrite that reads better to the author and does
  worse on the cases that used to pass gets caught at `run.sh`, not in production three
  weeks later when someone notices the skill stopped catching the thing it used to catch.
- **Verifier theater.** A green eval battery that doesn't actually exercise the skill's
  claims — cases so soft they'd pass against almost any output — is worse than no
  battery at all, because it's a false signal people build on. A case only earns its
  place if you can name a plausible wrong answer it would have caught.

## Anti-patterns

- **Model-in-the-loop scoring for the floor.** Reserve model grading for what it's
  actually suited to — whether a skill triggers on an ambiguous prompt — and never use it
  to score the deterministic floor. A model-graded pass/fail on "did the output follow
  the rule" is not reproducible, drifts as the grading model's version changes, and turns
  every regression debate into "well, it said pass." Grep it, diff it, check the exit
  code, or don't claim it's tested.
- **Editing the case to make a failing skill pass.** If a case fails after a change, fix
  the skill — or, if the case's expected property was genuinely wrong to begin with,
  replace it with a clearly-justified correction reviewed in the same change. Quietly
  loosening the assertion until the red goes away, in the same edit that broke it, is a
  battery lying to its own maintainer.
- **One case per behavior, called "coverage."** A single passing case tells you the
  skill worked once, on one input. Real coverage means a few cases per behavior,
  including at least one genuine near-miss — something that looks like it should trip
  the rule but shouldn't, and vice versa — the same discipline a marketplace's own
  triggering-eval convention already asks of you with negative controls.
