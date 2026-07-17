---
name: webhook-fast-ack
description: Design or fix a webhook receiver so it acknowledges the provider inside its response deadline and does the real work somewhere else — the fix for handlers that time out, silently drop events, or double-process retried deliveries. Use when a user is building a new webhook endpoint or receiver; when they describe a webhook handler timing out, being marked "failed" in a provider dashboard, or events that seem to vanish under load; when the same event appears to trigger downstream action twice; when they're integrating GitHub, Stripe, Slack, or any other provider's webhooks and ask how to structure the endpoint; or when they ask how to make a webhook handler idempotent, respond fast, process events in the background, or survive a traffic spike without losing deliveries. Trigger phrases include "webhook handler timing out", "webhook keeps failing", "process the webhook asynchronously", "idempotent webhook handler", "ack fast", "respond 202", "duplicate webhook events", "webhook retries".
---

# Webhook Fast Ack

Teaches an agent (any agent, any stack) how to design a webhook receiver that survives
its provider's response deadline: acknowledge the delivery immediately, do the actual
work somewhere the deadline can't touch it, and make that work safe to run more than
once. This is not about picking a queue technology — it's about the shape every
webhook receiver needs regardless of what's behind it: a fast, narrow, durable front
door, and a separate, unhurried back room.

## The deadline is the constraint

Every webhook provider imposes a response deadline, and none of them will wait for
you past it. The exact number and what happens if you miss it varies by provider —
look up the current numbers before you build — but the shape is universal:

| Provider class | Response deadline | If you miss it |
|---|---|---|
| GitHub-style | ~10 seconds | no automatic retry — the delivery is marked failed and stays failed unless you manually replay it |
| Stripe-style | ~20 seconds | retried with exponential backoff spread over multiple days |
| Slack Events API-style | ~3 seconds | retried a handful of times, backing off over minutes |

The two failure modes these produce are opposite and both bad. A provider that
**doesn't** retry turns a missed deadline into silent, permanent event loss — nothing
crashes, nothing errors, the automation that should have run just never does. A
provider that **does** retry turns a missed deadline into duplicate delivery — the
same event arrives twice, and anything not built to tolerate that double-charges,
double-sends, or double-writes. Fixing the first without the second (acking fast but
not idempotently, or vice versa) only trades one failure mode for the other.

## The pattern

```
POST /webhooks/<provider>
  1. verify authenticity (signature/HMAC check) — cheap, synchronous, non-negotiable
  2. durably append the raw event, keyed on the provider's unique delivery/event id,
     idempotent on that key (insert, on-conflict-do-nothing or equivalent)
  3. respond 2xx — 202 Accepted is the honest status: accepted, not yet processed

—— deadline pressure ends here ——

(a separate process, no deadline, no request context)
  4. read unprocessed rows from the durable log
  5. classify -> act -> whatever the real side effects are
  6. mark the row processed exactly once, guarded so a crash-and-retry of the
     worker itself can't double-act (e.g. "update ... where processed_at is null")
```

The request-path code should be capable of exactly one thing: verify, append,
respond. It should not hold credentials to call downstream APIs, touch business
tables, or branch on event content beyond "have I already stored this id." Minimizing
what the highest-exposure code in your system — the part reachable by anyone who
knows the URL, running under a hard deadline — is *capable* of doing is worth more
than any amount of care in how it's written.

## Failure modes this pattern prevents

- **Silent loss on a non-retrying provider.** A slow handler breaches the deadline,
  the provider marks the delivery failed and does not retry, and nothing on your side
  ever notices — no crash, no log line, just an automation that quietly never ran.
- **Duplicate side effects on a retrying provider.** The provider does exactly what
  its docs say (retries on a missed deadline), and a handler without an idempotency
  guard acts on the same event twice.
- **Cascading timeouts under load.** Heavy synchronous work in the request path — a
  downstream API call, an email send, a slow write — has a latency budget that's fine
  on average and blown the moment traffic spikes, turning one slow dependency into a
  wave of failed deliveries all at once.
- **Ack-before-durable-write races.** Responding 2xx before the event is durably
  stored looks like a fast ack but isn't a safe one: a crash in the gap between
  "respond" and "actually persist" loses the event while the provider believes it
  succeeded. Fast and durable are two different requirements — meeting one doesn't
  imply the other.
- **Unbounded reprocessing.** Without a processed-exactly-once guard, anything that
  can reinvoke a partially-failed worker — a cron sweep, a manual replay, a restart —
  will act on the same event again.

## Recovery: use the provider's replay mechanism

Don't build a custom retry/backoff sender to recover events you missed — most
providers worth integrating already expose one. GitHub has a redelivery endpoint for
past deliveries; other providers expose an equivalent "list what you were sent" or
"resend this event" call. The provider is the source of truth for what was sent; your
durable log is the source of truth for what you've processed; recovery is diffing the
two and replaying the gap through the provider's own mechanism, not reinventing it.

## Anti-patterns

- **Heavy lifting in the request path.** Calling a downstream API, sending an email,
  or doing a slow query before responding is the single most common cause of a
  provider reporting your endpoint as failed.
- **Ack-then-persist ordering.** Responding before the durable write has landed, not
  after or atomically with it — see the race above. A handler that "responds fast"
  by this measure has not actually solved the problem.
- **Trusting delivery order or delivery count.** No mainstream provider guarantees
  exactly-once or in-order delivery. A handler that assumes either will eventually
  corrupt state, usually under exactly the load conditions you can least afford it.
- **"We're probably fine at our current volume."** This pattern is deadline-classed,
  not volume-classed. A handler with a comfortable average latency is one downstream
  hiccup away from a spike of breached deadlines. Build the split before volume
  forces it, not after a provider dashboard starts showing failures.

## Refusals

- Won't help you skip or weaken signature/authenticity verification to buy time
  inside the deadline. Verification is cheap enough to fit; if it doesn't, the crypto
  call is misconfigured — that's not a reason to trust unverified input.
- Won't help you build a receiver that drops malformed or unrecognized payloads
  without a trace. Reject fast, but reject loud: log or journal what was rejected and
  why. Silent rejection is indistinguishable from silent loss to whoever debugs it
  later.
- Won't help you design "eventually idempotent" handlers that rely on a comment or a
  convention instead of a structural guard — a unique constraint, a processed-at
  check. A rule enforced only by someone remembering it isn't enforced.
- Won't recommend building a custom redelivery or backoff sender in place of a
  provider's own replay API. That's re-solving a problem the provider already solved,
  usually worse.
- Doesn't cover general message-queue or broker selection, auth/authz for the rest of
  the application, or vendor SDK setup. This skill is specifically the request-path /
  async-path split and the idempotency it requires — not everything downstream of it.
