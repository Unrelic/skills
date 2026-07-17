---
name: sql-door-functions
description: Design the SQL write path for a Postgres or Supabase table so every write crosses a single audited SECURITY DEFINER "door" function instead of a raw table grant. Use when a user is deciding what an API role (anon, authenticated, service_role, or any custom writer role) should be allowed to write to a table; when they ask about SECURITY DEFINER functions, row-level security write policies, revoking EXECUTE from PUBLIC, or building an append-only ledger or audit table; when they ask "how do I stop this role from writing directly to this table" or "is my SECURITY DEFINER function actually locked down"; or when they mention putting a service-role key in a client. Trigger phrases include "door function", "SECURITY DEFINER", "revoke execute from public", "service_role in the client", "append-only ledger", "write path", "who can write to this table", "RLS bypass".
---

# SQL Door Functions

Teaches an agent (any agent, any stack) how to design the write path into a Postgres
or Supabase table so that no role — not the API role the client authenticates as, not
the server's own service role — can write to the table directly. Every write crosses
exactly one **door**: a `SECURITY DEFINER` function that validates its inputs,
enforces the table's invariants in SQL, and is the only thing holding a table grant.
This is not about wrapping every table in a function for its own sake — a door earns
its existence by being the one place a write's legality is decided, auditable, and
impossible to route around.

## The door pattern

A door function has four properties, all four, every time:

1. **It is `SECURITY DEFINER`.** It runs with the privileges of its owner, not its
   caller, so the caller needs no direct table grant at all.
2. **It is the only write path.** The underlying table has no INSERT/UPDATE/DELETE
   grants to any API role — not `anon`, not `authenticated`, not `service_role`. If a
   role can `insert into` the table directly, the door is decorative.
3. **It validates before it writes.** Every invariant the write must satisfy is
   checked in the function body (or, better, in a table `CHECK` constraint the
   function can't bypass either) — never assumed from the caller's good behavior.
4. **Its own grant is narrow.** `EXECUTE` goes to exactly the role(s) that should be
   able to attempt this write — never to `PUBLIC`, never to every API role by default.

```sql
-- schema: acme (generic example — substitute your own)
create table acme.orders (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references acme.tenants(id),
  total_cents integer not null check (total_cents >= 0),
  status      text not null default 'pending'
              check (status in ('pending', 'paid', 'cancelled')),
  created_at  timestamptz not null default now()
);

-- No INSERT/UPDATE/DELETE policy or grant exists for acme.orders.
-- The only way in:
create function acme.create_order(
  p_tenant_id   uuid,
  p_total_cents integer
) returns uuid
language plpgsql
security definer
set search_path = acme, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into acme.orders (tenant_id, total_cents)
    values (p_tenant_id, p_total_cents)
    returning id into v_id;
  return v_id;
end;
$$;
```

## Revoke PUBLIC first — the gotcha

Postgres grants `EXECUTE` on every new function to `PUBLIC` by default. A
`SECURITY DEFINER` function created in a schema the API can reach is a public,
unauthenticated endpoint the instant it's created — not after someone remembers to
lock it down later. The revoke isn't cleanup, it's the first grant statement, and it
has to run before you grant anything back:

```sql
revoke execute on function acme.create_order(uuid, integer) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke execute on function acme.create_order(uuid, integer) from authenticated';
  end if;
end;
$$;

grant execute on function acme.create_order(uuid, integer) to acme_order_writer;
```

Guard grant/revoke statements against the role existing (a `pg_roles` check inside a
`do` block) so the same migration runs on a plain Postgres test database and on a
Supabase project with `anon`/`authenticated`/`service_role` present — a migration
that only works against one environment isn't portable, and you want the same
migration tested locally that ships.

## Writer roles hold no table privileges

The role a client or server authenticates as should never appear in a
`grant insert|update|delete ... to <role>` statement, full stop — including
`service_role`. A `service_role`-equivalent key that bypasses RLS is not a substitute
for a door; it's a bigger door with no lock. If your server process needs to write,
it authenticates as a role that holds `EXECUTE` on the doors it needs and nothing on
the tables underneath. A leaked key, a logged request, a misconfigured client — none
of them turn into a direct-write incident, because there is no direct write to have.

## Validate inside the door — constraint-shaped, deterministic

Push every invariant you can into a `CHECK` constraint on the table itself — a
constraint can't be forgotten by a future door and can't be bypassed by a second door
someone adds later without reading this one. What can't be expressed as a `CHECK` (a
lookup against another table, a monthly cap, a lock-and-recompute) goes in the
function body, before the write, and it fails loud:

```sql
if not exists (select 1 from acme.spend_caps where tenant_id = p_tenant_id) then
  raise exception 'no spend cap row for tenant % — fail-closed, write rejected', p_tenant_id
    using errcode = 'P0001';
end if;
```

Keep the check deterministic — a `select ... for update` and arithmetic, not a call
out to anything nondeterministic or external. A door that can't be replayed
identically against the same rows isn't auditable.

Pin `search_path` explicitly (`set search_path = acme, pg_temp`, or
`pg_catalog, public` for a function whose logic depends on an unshadowable built-in
like a hash function) on every `SECURITY DEFINER` function. Without it, a caller who
can create objects earlier in their session's `search_path` can shadow a function or
operator the door relies on and change what it does — the definer runs with the
owner's *privileges*, but an unpinned `search_path` still resolves at the caller's
whim.

## auth.uid() and identity: RLS does not follow you into the door

Row-level security policies are evaluated for the role actually running the query.
Inside a `SECURITY DEFINER` function, that's the function's *owner* — typically a
privileged role — not the original caller. That means the SELECT/UPDATE queries a
door runs against its own tables do not get filtered by the RLS policies written for
`authenticated`, even though the caller who invoked the door is subject to them
everywhere else. This is the single most common way "we have RLS" turns out to mean
nothing at the write path.

Two shapes, pick deliberately:

- **The door is called only by a narrow server-side role** (your backend, not the
  end-user's session), and identity/authorization was already checked at the layer
  that decided to call it. This is fine — but then `EXECUTE` must be granted to that
  narrow role alone, never to `authenticated`, or you've silently promoted every
  logged-in user to that trusted caller.
- **The door is called directly by `authenticated`** (a client-side Supabase call).
  Then the door's body must re-derive and check identity itself — `auth.uid()`
  against an owner column, or the caller's tenant against a membership table —
  before it touches a row. RLS will not do this for you here; the `if` statement is
  the whole enforcement.

```sql
if p_tenant_id not in (select tenant_id from acme.tenant_members
                         where user_id = auth.uid()) then
  raise exception 'not a member of tenant %', p_tenant_id using errcode = '42501';
end if;
```

## Append-only ledgers

When the domain is a ledger — anything where a row, once written, must never
silently change — don't rely on "nobody has an UPDATE grant." Add a trigger that
rejects `UPDATE`/`DELETE`/`TRUNCATE` outright, for *every* role, including the table
owner and any role with `BYPASSRLS`:

```sql
create function acme.block_mutation() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  raise exception '% is append-only: % rejected (corrections are new rows)',
    tg_table_name, tg_op using errcode = 'P0001';
end;
$$;

create trigger ledger_entries_append_only
  before update or delete on acme.ledger_entries
  for each row execute function acme.block_mutation();

create trigger ledger_entries_no_truncate
  before truncate on acme.ledger_entries
  for each statement execute function acme.block_mutation();
```

A correction is a new row referencing the one it corrects, never an edit. This is
what makes the ledger auditable independent of who currently holds what grant —
grants can be misconfigured; a trigger that fires unconditionally cannot be.

## What this prevents

- **RLS bypassed by the definer.** A door that assumes its own SELECT/UPDATE queries
  are tenant-scoped because "we have RLS" — they aren't, inside a definer, unless the
  body checks explicitly. See the `auth.uid()` section above.
- **UPDATE without WITH CHECK.** An RLS `UPDATE` policy with a `USING` clause but no
  `WITH CHECK` lets a row that's visible for update be rewritten into a row that
  wouldn't be — most dangerously, a caller reassigning a `tenant_id` (or any owner
  column) to move a row into a tenant they don't belong to. Write both clauses, or
  add an immutability trigger on the identity column as a second, RLS-independent
  wall — `before update ... when (new.tenant_id is distinct from old.tenant_id)
  raise exception`.
- **`service_role` (or any bypass-RLS key) reaching a client.** The moment a
  service-role-equivalent credential is readable from browser code, a mobile app, or
  a public repo, every table it can reach is one leaked key away from an
  unrestricted write. Doors make the blast radius of a leaked client credential
  "nothing" instead of "everything," because the client's role never had table
  privileges to begin with.
- **A door with a public `EXECUTE` grant.** Forgetting the `revoke ... from public`
  turns a reviewed, invariant-checking function into an unauthenticated write
  endpoint that happens to have nice validation.

## Refusals

- Refuse to grant `INSERT`, `UPDATE`, `DELETE`, or `TRUNCATE` on a table to `anon`,
  `authenticated`, `service_role`, or any client-facing role — route these through a
  door instead, every time, no "just for now."
- Refuse to leave a newly created `SECURITY DEFINER` function without an explicit
  `revoke execute ... from public` in the same migration. Don't defer it to a
  follow-up.
- Refuse to write a `SECURITY DEFINER` function without `set search_path`. An
  unpinned search path in a definer function is a standing vulnerability, not a
  style nit.
- Refuse to mark a table "ledger" or "append-only" in comments or docs without also
  adding the mutation-blocking trigger. A convention nobody enforces isn't
  append-only, it's append-mostly.
- Refuse to design around a service-role (or equivalent bypass-RLS) credential being
  present in any client-side code path, regardless of how the request is framed
  ("just for this internal tool", "it's not really public"). Point to a door
  instead.
