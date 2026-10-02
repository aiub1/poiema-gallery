# 0014 — Public events: anonymous read through `public_*` functions

Status: accepted · Date: 2026-10-02

## Context

Until now the system was closed: `anon` had no privilege on any table and
every read required an active profile (`is_member()`). The GetUp 2026 site
(`getup-gallery`, a separate app from `galeria-web`) needs the opposite for
one event: photos that anyone can view and download without logging in.

This is the first read without login in the project and it changes a
sentence in `CLAUDE.md` §1 ("closed system, no anonymous access").

## Decision

1. `events` gets `is_public boolean not null default false`. Only `admin` may
   turn it on or off, enforced by trigger `trg_events_public_flag` (the
   `update events` policy lets the creator edit their own row, so a policy
   alone would let an uploader open an event to the public).
2. `anon` **keeps zero privileges on every table**. The guard in
   `010_schema_guards.sql` is unchanged and still green. Public reads go
   through four `security definer` functions with `execute` granted to
   `anon`: `public_event(slug)`, `public_event_sessions(slug)`,
   `public_event_photos(slug, session_id, limit, offset)` and
   `public_photo(id)`.
3. The public rule is defined once, in the internal `public_photos_of(event_id)`
   (no grant to `anon`/`authenticated`): event is public and not deleted;
   photo not deleted, `status <> 'pending_review'`, **`contains_minors is
   false`** (null or true is never public) and `not is_private`.
4. The functions return only `id`, `session_id`, `thumb_key`, `web_key`,
   dimensions and `taken_at` (plus event/session labels). Never
   `storage_key`, `uploaded_by`, `status` or the flags.
5. No existing policy changes: `read photos`, `read events` and `read
   sessions` stay as they are.

## Alternatives considered

- **`select` policies for `anon` on the tables.** Needs a table-level grant to
  `anon`, which breaks the structural guard and moves from "anon can call
  four audited functions" to "anon is one wrong policy away from reading
  `photos`". Rejected.
- **The web reads with `service_role` and filters.** Makes the web decide
  who sees what, against `CONTRATO.md` §1 ("the web never decides who can see
  what"), and puts the key that bypasses RLS on a public-facing code path.
  Rejected.

## Consequences

- The public site never shows a photo with minors, even for a public event.
  If an event has many teenagers the public gallery will be thin; changing
  that means revisiting `CLAUDE.md` §3 and the LGPD analysis, not just this
  migration.
- The `public_*` functions are now public surface. Any column added to their
  return types needs review, and the leak test in
  `supabase/tests/07_public_events.sql` must be extended with it.
- Facial indexing in public events: a visitor of an open event has not signed
  the biometric consent, so the public site may publish a photo without
  minors **without** enqueuing `index_faces` (row inserted with
  `status = 'skipped'`). See `CONTRATO.md` §9.
- `CONTRATO.md` goes to 1.2 and must be copied to `galeria-web`.
- The migration is applied to the remote only through the manual workflow
  with dry-run ([ADR 0013](0013-manual-migrations-dry-run.md)).
