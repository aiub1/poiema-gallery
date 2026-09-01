# 0003 — Profile provisioning and the first admin

Status: accepted · Date: 2026-08-24

## Context

`profiles.id` references `auth.users(id)`, but nothing created the row. A user
who signs up ends with an `auth.users` record and no profile, which makes
`my_role()` return null and leaves them unable to see anything — including any
indication of why. There was also no path to the *first* admin: no policy lets a
non-admin set `role = 'admin'`, so an empty `profiles` table stays adminless
forever.

## Decision

### 1. A trigger provisions the profile

`trg_on_auth_user_created` fires `after insert on auth.users` and inserts into
`public.profiles` with `role = 'member'` and **`is_active = false`**.

`full_name` comes from `raw_user_meta_data ->> 'full_name'` when the invite
carries it, otherwise the placeholder `Novo membro`. The e-mail local-part was
rejected as a fallback: `profiles` is readable by every active member, and
scattering fragments of e-mail addresses across a table everyone reads works
against `CLAUDE.md` §5.2.

### 2. New profiles start inactive

This is the deliberate part, and it deviates from "create it active".

`is_member()` requires `is_active`, and every read policy in the system goes
through `is_member()`. An inactive profile therefore sees nothing but its own
row. Activation is an explicit admin act.

The reasoning: the alternative design leans entirely on the Supabase Auth
console being set to invite-only. That setting is **not visible from this
repository**, is not under version control, cannot be asserted in a test, and
can be flipped by anyone with console access without leaving a trace in git. A
security property that no one can verify by reading the repo is not a security
property. Starting inactive moves the guarantee into code, where pgTAP can hold
it (`020_profiles_rls.sql`, scenario 17).

The cost is one admin click per legitimate member. For a church of this size
that is a rounding error against the failure mode it prevents.

### 3. The first admin is created directly in the database

By hand, once, against the remote:

```sql
-- Replace the e-mail. Run as the `postgres` role, in the SQL editor.
update public.profiles
   set role = 'admin', is_active = true
 where id = (select id from auth.users where email = 'secretaria@exemplo.org');
```

This is the **only** authorized manual mutation of `profiles.role` in the
project's lifetime. Every subsequent admin is promoted by an existing admin
through the normal policy path.

For this statement to work, `enforce_profile_privileged_columns()` exempts
`postgres`, `supabase_admin` and `service_role` — see below.

## The privileged-column guard and its escape hatch

`role` and `is_active` are frozen for non-admins by a `before update` trigger
rather than by a `with check` expression (see ADR discussion in PR 1). The
trigger is deliberately **security invoker**: inside a `security definer`
function `current_user` resolves to the function owner, which would make the
role check meaningless. As an invoker function, `current_user` is the effective
role — `authenticated` for PostgREST traffic, `postgres` for psql and seeds.

Exempted roles: `postgres`, `supabase_admin`, `service_role`. Without the
exemption the bootstrap statement above would fail (no admin exists yet to
authorize it) and `seed.sql` could not build fixtures.

## ⚠️ Dependency: Supabase Auth signup mode

**This design assumes signup is restricted to invitation.** Written down here so
that whoever reopens it in the future knows exactly what they are trading away.

Where to check:

- **Remote:** Dashboard → Authentication → Sign In / Providers →
  *Allow new users to sign up*.
- **Local:** `supabase/config.toml`, `[auth] enable_signup`.

If signup is reopened:

| | Consequence |
|---|---|
| Any e-mail on the internet | can create an `auth.users` row |
| The trigger | will create a `profiles` row for it — by design, it cannot tell an invite from a walk-in |
| The intruder's visibility | **none**, because `is_active = false` and `is_member()` gates every read policy |
| What is actually lost | the `profiles` table accumulates junk rows, and an admin who bulk-activates without checking hands over the whole archive |

So: reopening signup is survivable but degrades the guarantee to "an admin must
not click Activate carelessly". Keep it closed. If it must be opened, add an
invitation allow-list table checked by the trigger before it inserts, and revisit
this ADR.

## Consequences

- Deactivation is the only removal path. `delete` on `profiles` is revoked from
  everyone (see PR 1) — deleting the profile while `auth.users` survives would
  let the user log back in and be re-provisioned by the trigger, in a loop.
- `handle_new_auth_user()` has `execute` granted only to `supabase_auth_admin`;
  `authenticated` and `anon` cannot call it directly.
- The trigger is idempotent (`on conflict (id) do nothing`), so replaying an
  `auth.users` insert cannot clobber an existing profile.
