# Contributing

Thanks for considering a contribution. This repo is small on purpose — quality bar
over coverage. A few rules:

## PRs only

All changes land via pull request, reviewed like code. No direct pushes to `main`,
including from maintainers. A skill is a set of instructions an agent will follow
autonomously; it deserves the same review rigor as anything else that runs.

## Evals required

Every skill must ship an `evals/evals.json` alongside its `SKILL.md`. At minimum,
include:

- A couple of cases where the skill should explicitly trigger (the user names the
  skill's domain outright).
- A couple where it should trigger implicitly (the user describes the problem without
  naming the skill).
- A couple of negative controls — realistic prompts that are adjacent to the skill's
  domain but should **not** trigger it. Negative controls that are obviously unrelated
  ("write a fibonacci function") don't test anything; make them genuine near-misses.

A PR that adds or meaningfully changes a skill without updating its evals will be
asked to add them before merge.

## Security posture

Skills execute with the authority of whatever agent loads them. Treat every skill as
you would a dependency with shell access, because for most agents that's exactly what
it is.

- **No curl-pipe-bash.** A skill must not instruct the agent to pipe a remote download
  straight into a shell (`curl ... | sh`, `iwr ... | iex`, etc.). If a skill needs a
  script, the script ships in the skill's own directory, reviewed in the same PR.
- **No remote-fetched instructions.** A skill must not tell the agent to fetch
  instructions from a URL and then follow them. Everything the agent is meant to do
  lives in the reviewed `SKILL.md` and its bundled files — not behind a link that can
  change after merge.
- **Reviewed like code.** Assume a skill will be read by reviewers who are looking for
  exactly the kind of prompt-injection or scope-creep risk you'd look for in a new
  dependency. Keep instructions specific to what the skill claims to do.

## Style

- Keep `SKILL.md` bodies lean — an agent reads the whole thing every time the skill
  triggers, so the non-negotiable content belongs inline (agents skip reference files
  under time pressure) and everything else belongs in `references/` if it's needed at
  all.
- Frontmatter `description` should state both what the skill does and concrete phrases
  that should trigger it — that field is the entire triggering signal.
- Write for any agent on any stack. Nothing in this repo should assume a specific
  company's internal tools, repos, or names.

## Getting started

Fork, branch, add or edit a skill under `skills/<skill-name>/`, add or update its
evals, open a PR. Describe what you tested and how in the PR body.
