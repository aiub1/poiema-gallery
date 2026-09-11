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
| 0001 | `20260830060023_foundation.sql` | `user_role`, `profiles` (role helpers, privileged-column guard, `auth.users` provisioning trigger), `events`, `sessions` |
| 0002 | `20260910224708_phase2_photos.sql` | `events` soft delete, `photos`, `photo_faces` (antecipada — [ADR 0004](0004-events-soft-delete-and-photo-faces-timing.md)), `removal_requests`, `jobs`, `access_logs` |
| 0003 | `20260911054031_phase3_minors.sql` | `minors`, `guardians`, `minor_consents`, `photo_minors`, `is_guardian_of_photo()`, `read photos` versão intermediária ([ADR 0005](0005-read-photos-phase-progression-and-consent-scope.md)) |
| 0004 | `20260911062131_schema_cleanup_pendencias.sql` | `profiles_full_name_not_blank`, índice único normalizado `sessions_event_id_name_key` ([ADR 0008](0008-session-name-uniqueness-normalized.md)), `events_created_by_idx` — fecha as três pendências de `ARQUITETURA.md` §15 |

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
Helper functions therefore **cannot** live before the table they read.
Required order within `0001` (`20260830060023_foundation.sql`):

```
profiles → helper functions → enable rls → policies → grants → other tables
```

This is a property of `profiles` specifically, because it is the table the
authorization helpers are built on — the constraint applies to the whole file,
since `0001` also brings `events` and `sessions` after it. Those two only
consume the helpers and have no such constraint among themselves; either could
come first. Later tables outside this file (`photos`, and everything from
phase 3 on) only consume the helpers too and have no ordering constraint with
`profiles`.

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
