# Unrelic Skills

Agent Skills from [Unrelic](https://unrelic.com) — patterns for building automation
that AI can run and a human can trust, because the irreversible steps are gated.

This repo is a public library of [Agent Skills](https://www.anthropic.com/news/skills):
portable, model-agnostic instructions that teach an agent how to do something well,
loaded on demand rather than crammed into a system prompt. Every skill here is about
one thing specifically: **designing automation where the AI conducts and a human gates
the irreversible steps.** Approval gates, digest-bound acks, reversibility tests,
fail-closed defaults — the parts of an agentic system that keep it safe to leave running.

## The promise

Every skill in this repo ships with an `evals/` directory: concrete test cases that
check whether the skill triggers when it should (and stays quiet when it shouldn't),
and whether following it produces the behavior it claims to teach. We don't publish
a skill we haven't tested against real prompts. See each skill's `evals/evals.json`.

## Install

**Via the [`skills` CLI](https://github.com/vercel-labs/skills) (works with any agent that reads `SKILL.md` files):**

```bash
npx skills add Unrelic/skills
```

This copies the skill(s) you choose into your project or global skills directory.

**Via the Claude Code plugin marketplace:**

```
/plugin marketplace add Unrelic/skills
/plugin install unrelic-skills
```

Claude Code will read [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)
in this repo and install the skills it lists.

## What's here

| Skill | What it teaches |
|---|---|
| [`approval-gate-design`](skills/approval-gate-design/SKILL.md) | How to design a human-approval gate into an agentic workflow: the reversibility test, digest-gated acks, tiering, and the anti-patterns that turn a gate into theater. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: PRs only, no curl-pipe-bash,
no skill that fetches remote instructions at run time, and every skill is reviewed
like code because it runs like code.

## License

[MIT](LICENSE) — copyright 2026 Unrelic.
