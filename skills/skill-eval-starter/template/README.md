# eval battery starter template

Copy this whole directory into your own skill (e.g. `your-skill/evals/`) and adapt it —
it's a working, self-contained example, not pseudocode.

```
bash run.sh              # run every case, write results.json, exit nonzero on regression
bash run.sh --baseline   # also overwrite baseline.json with this run (the new floor to beat)
```

## Layout

- `cases/<id>/case.json` — one fixture per case. `run.type` picks the scorer
  (`grep-absent`, `grep-present`, or `script`); `expect` is the known-good verdict +
  exit code, never a fuzzy string match.
- `checks/` — deterministic scorer scripts for the `script` run type. `exact-match.sh`
  is the included example: a byte-for-byte `diff` between `expected.txt` and
  `actual.txt` inside the case directory.
- `split.json` — which case ids are `held_out` (never touched while you're iterating on
  the skill's prose) versus `train` (fair game). Prevents overfitting the words to your
  own test.
- `baseline.json` — the committed floor. `run.sh` doesn't diff against it automatically
  (that's a judgment call for your CI or review process), but it's the number you
  publish and the number a regression shows up against.
- `results.json` — generated fresh by every run. Not meant to be hand-edited or
  committed as the source of truth; `baseline.json` is.

## To bootstrap your own skill's battery

1. Delete `cases/example-case/` and `cases/example-script-check/` (or keep them as a
   reference while you write your first real case alongside them).
2. Add a case directory per behavior you want pinned: a fixture file plus a `case.json`
   declaring the check type and the expected property.
3. Update `split.json` with your real case ids, keeping a genuine holdout slice.
4. `bash run.sh --baseline` once you're happy — that's the floor from now on.
5. Wire `run.sh` into whatever gate merges changes to the skill (CI, a pre-merge hook,
   a review step) so a regression fails loudly instead of shipping quietly.
