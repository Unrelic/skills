---
name: approval-gate-design
description: Design a human-approval gate into an agentic or automated workflow — where to put it, what makes an approval real instead of theater, and how to fail closed. Use when a user asks to add an approval step, a review gate, a human-in-the-loop checkpoint, or a confirmation flow to an agent/automation; when they describe wanting to run an agent unattended or overnight but need it to be "safe"; when they ask how to make an action reversible or undoable before an agent takes it; or when they're deciding what an autonomous system should be allowed to do without asking first. Trigger phrases include "add an approval step", "human in the loop", "make this safe to run unattended", "should this need sign-off", "approval gate", "review gate", "confirmation before it does X".
---

# Approval Gate Design

Teaches an agent (any agent, any stack) how to decide *where* a human approval gate
belongs in an automated workflow, and how to build a gate that is actually binding
rather than decorative. This is not about adding confirmation dialogs everywhere —
over-gating is its own failure mode, because a human who is asked to approve
everything stops reading and starts rubber-stamping. The goal is exactly one gate,
in exactly the right place: the point past which the system cannot take back what
it did.

## The reversibility test

An action is reversible only if it passes **all three** clauses. Failing any one
clause makes it irreversible, and irreversible work needs a human gate before it
happens, not a report after.

1. **Unilateral undo.** You can undo it yourself, right now, without anyone else's
   help — a `git revert`, a file delete, a draft retraction. If undoing requires
   asking someone else to cooperate, it isn't unilateral.
2. **Nothing crossed the boundary.** Nothing left your system onto a shared surface,
   to a customer, or into a third-party system where another party may already have
   observed or relied on it. A delete does not un-read something a person already
   saw. A rollback does not un-observe a live deploy. This clause is the one people
   get wrong most often: they reason "I can revert the commit" and stop there,
   forgetting that a merge to a deploy branch was already seen the instant it went
   live.
3. **No external commitment.** No money moved, no message reached a human, no
   credential was widened, no release was cut, no data left the system's boundary
   (PII or otherwise). Any of these is a commitment made on the world's behalf, and
   the world doesn't roll back on your schedule.

**Egress is the irreversibility axis.** Data leaving the boundary — a secret, a
customer record, a document — is irreversible the instant it leaves, no matter how
small or how quickly you notice. A reverted commit doesn't un-leak a secret that was
in it.

## Tiering the work

Once you can classify an action against the test above, route it:

- **Reversible AND intent is inferable from a cited record** (a spec, a ticket, prior
  instructions, an established pattern) → act, then report what you did and the
  record you inferred it from. Do not ask first. Asking about work that is both safe
  to undo and clearly intended trains the human to stop reading confirmation
  requests, which breaks the gate for the moment it actually matters.
- **Irreversible, OR the record is genuinely silent or conflicting on this specific
  decision** → stop and gate. A genuine fork is not "I'm not 100% sure" — confidence
  is not the criterion (see anti-patterns below). It's "the record does not answer
  this, and getting it wrong cannot be undone."

A gate is a spend, not a reflex: every time you route to a human, you should be able
to say what you checked first and why it didn't resolve the question. A gate thrown
up without first consulting the available record is as much a violation as skipping
a gate that was needed.

## The digest-gated ack

An approval is only real if it is bound to the *exact content* being approved. A
human clicking "approve" on a stale summary of what will happen is not an approval —
it's theater, because the system can't actually prove what was approved matches what
runs.

Bind every gate to a content digest (sha256 of the exact payload — the diff, the
message text, the transaction parameters):

- If the content changes after the human has seen it, the ack is void. Re-render and
  re-request.
- If an ack comes back that doesn't match the current digest (stale approval, replay,
  a human approving the wrong version), do not proceed — journal the mismatch and
  keep the workflow parked, waiting.

**Concrete card format** — what a gate request should contain, every time:

```
WHAT:     <one line: the action being requested>
LINK:     <where to see the full content — diff, draft, transaction>
GATE:     <who owns this approval>
DIGEST:   sha256:<hash of the exact content being approved>
UNDO:     <what happens if this needs to be reversed after approval — or
           "none: irreversible once confirmed" if that's the truth>
```

The `UNDO` line matters even for gated actions — it tells the approver what recourse
exists (or doesn't), which is part of what they're actually approving.

## Fail-closed defaults

When the system doesn't know, it should not guess in the direction of action:

- **Unknown classification** (the action doesn't clearly match a known reversible or
  irreversible category) → route to a human. Don't default to "probably fine."
- **Missing manifest or spec** for what a component is allowed to touch → treat it as
  sealed / locked, not as open by default.
- **No budget or authorization row** for a spend → no spend happens, full stop, not
  "proceed and reconcile later."

Fail-closed only works if it's enforced structurally (a check that blocks the action)
rather than by convention (an instruction the agent is trusted to remember). A rule
that lives only in a prompt is a suggestion; a rule enforced by a gate the code
actually checks is a rule.

## Anti-patterns

- **Approval theater.** An ack without a digest check. It looks like a gate and
  behaves like a rubber stamp, because nothing verifies the human approved *this*
  content rather than an earlier or different version of it.
- **Gate-by-vibes.** Using confidence as the gating criterion instead of
  reversibility — "I'm pretty sure this is fine" is not a substitute for "this passes
  the three-clause test." A confident agent and a reversible action are unrelated
  facts; conflating them is how irreversible actions slip through on a good day.
- **Self-review of safety changes.** The component that verifies an action's safety
  should never be the same component (or session) that just modified the safety
  logic itself. A change to the gate needs a *different* reviewer than the one who
  wrote it — verifier and author are different roles even when they're the same
  agent on different days.
- **Gating everything.** The inverse failure: asking for approval on reversible,
  clearly-intended work. This doesn't make the system safer — it teaches the human to
  stop reading gate requests, which is strictly worse than not gating, because now
  the *real* gates get rubber-stamped too.
