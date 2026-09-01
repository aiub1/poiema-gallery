# 0002 — Migration conventions

Status: accepted · Date: 2026-08-24

## Context

`CLAUDE.md` §5.1 requires migrations to be "numbered and immutable once
applied". The Supabase CLI generates and tracks migrations by UTC timestamp
(`20260824120000_name.sql`) and stores that exact string in
`supabase_migrations.schema_migrations`. Mixing a hand-rolled `0001_` sequence
with CLI-generated timestamps breaks ordering on `supabase db push` and makes
the remote ledger diverge from the repository.

## Decision

**Filenames use the CLI timestamp.** The ordinal (`0001`, `0002`, ...) lives
only in the table below and in the header comment of each file. Both
conventions coexist without fighting: the timestamp is the machine's ordering,
the ordinal is the human's.

| # | File | Subject |
|---|---|---|
| 0001 | `20260824120000_create_profiles.sql` | `user_role`, `profiles`, role helpers, privileged-column guard |
| 0002 | `20260824120100_create_profile_provisioning.sql` | `auth.users` → `profiles` trigger |

New migrations are created with `npx supabase migration new <name>`, never by
hand-typing a timestamp.

### Immutability

A migration that has been applied to the remote is never edited — not even to
fix a typo in a comment. Changed your mind? New migration. A migration still
unapplied anywhere (not merged to `main`) may be edited freely.

### One table, one file, everything included

Per `CLAUDE.md` §5.1, a migration that creates a table ships in the same file:
`enable row level security`, every policy, every index, and every grant/revoke.
A table arriving without its policies is a bug, not a follow-up.

### Ordering constraint inside a single file

The policies on `profiles` call `my_role()`, which itself reads `profiles`.
Helper functions therefore **cannot** live in an earlier migration than the
table they read. Required order within `0001`:

```
table → helper functions → enable rls → policies → grants
```

This is a property of `profiles` specifically, because it is the table the
authorization helpers are built on. Later tables (`events`, `sessions`,
`photos`) only consume the helpers and have no such constraint.

## Consequences

- `supabase migration list` is the source of truth for what has been applied.
- Rollback is forward-only. There are no `down` migrations.
- Reviewers check the ordinal table above is updated in the same PR.

## Deferred: TypeScript type generation

`CONTRATO.md` §2 requires regenerating `database.types.ts` in `galeria-web`
after every migration. **That repository does not exist yet.** The obligation
is deferred, not waived. When `galeria-web` is created, the first task is:

```bash
npx supabase gen types typescript --local > ../galeria-web/lib/database.types.ts
```

...covering every migration merged up to that point, plus wiring the CI check
described in `CONTRATO.md` §2. Until then, no schema PR can be blocked by a
type-generation step that has nowhere to write.
