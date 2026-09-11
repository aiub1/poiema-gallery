# 0007 — Tofu state lives in its own R2 bucket, not the photos bucket

Status: accepted · Date: 2026-09-11

## Context

`ARQUITETURA.md` §9 says state goes to R2, but doesn't say which bucket.
The obvious shortcut is reusing the photos bucket (`cloudflare_r2_bucket.gallery`,
`infra/main.tf`) under a prefix like `infra/terraform.tfstate` — one fewer
bucket to create by hand, one fewer thing to explain.

## Decision

Use a **separate** bucket (`poiema-gallery-tfstate`), created manually the
same chicken-and-egg way the photos bucket is bootstrapped before Tofu can
manage state at all — see `infra/README.md`.

Reasons:

- **Blast radius.** The photos bucket's lifecycle, deletion job
  (`delete_objects`, `ARQUITETURA.md` §6) and access policy have nothing to
  do with Tofu state. A bug or a manual mistake in the worker's cleanup
  path should not be able to touch the file that reconstructs the whole
  infrastructure's source of truth.
- **Different sensitivity, different credential.** The R2 API token scoped
  to the state bucket only needs to be held by whoever runs `tofu
  apply` — not by the worker, which never needs write access to
  `infra/terraform.tfstate`. Sharing one bucket would force sharing (or
  needlessly widening) that credential's scope (`infra/README.md`,
  "Credencial S3-compatible do bucket").
- **No content overlap.** The two things stored have nothing in common —
  church photos on one side, a JSON blob of resource IDs on the other.
  Separate buckets is the free R2 tier's normal shape, not a stretch of it
  (`ARQUITETURA.md` §14).

## Consequences

- One more manual bootstrap step before the backend migration in
  `infra/README.md` can run: create `poiema-gallery-tfstate` by hand in the
  Cloudflare dashboard first (same manual step, same reasoning, as the
  photos bucket's own bootstrap — Tofu cannot create the bucket that then
  holds its own state).
- Two R2 buckets to account for against the 10 GB free-tier ceiling
  instead of one — state is a few KB, so this is not a real cost, just
  something to remember when reading the account's bucket list.
