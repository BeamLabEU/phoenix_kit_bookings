# PR #2 Review — Adopt core's `put_slug/3` for service slugs

**Author:** Max Don (mdon)
**Reviewed:** 2026-08-14
**Reviewer:** Grok (grok-4.6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_bookings/pull/2
**Merge:** `15ccdc3` (`433e11f` on the fork)
**Verdict:** APPROVED — already merged; pin raised to `~> 2.4` and released as 0.1.2

> A `phase1.md` from an earlier pass sits alongside this file. Its hold-for-merge
> gate ("do not merge until core ships `put_slug/3`") is now met: core **2.4.0**
> shipped the function and this repo's lock is on published **2.6.0**. The other
> self-flagged gap (no `@version` / CHANGELOG) is closed in the follow-up commit.

---

## The change

`Service.changeset/2` drops a local `maybe_generate_slug/1` whose slugify was
ASCII-only (`[^a-z0-9]` after downcase) for `PhoenixKit.Utils.Slug.put_slug(:name,
max_length: 160)`. Two real bugs go with it:

- **A Cyrillic or Greek service name could not be created.** The old slugifier
  produced `""`, which then failed this schema's own `validate_format(:slug, …)`.
  Core romanizes, so the same names now pass that validation.
- **Name collisions were raw constraint errors.** Nothing probed;
  `phoenix_kit_bookings_services_slug_index` is unique, so two services named
  alike blew up on insert. `put_slug` suffixes `-2`, `-3` … until free, and
  `max_length: 160` keeps the suffix inside the `VARCHAR(160)` column — the old
  `String.slice(0, 160)` could not, once a suffix was added.

Rename semantics are unchanged: an existing slug survives a name edit (the old
`get_field` check already got this right). `unique_constraint/3` against the
named index is still declared, which is what `put_slug`'s own docs require —
the probe is an allocator, not an integrity boundary.

The four new tests are the right shape. Exact transliteration is deliberately
not pinned (that is how `phoenix_kit_dashboards#5` merged red).

---

## Findings

### BUG - HIGH — the core pin admitted a core without `put_slug/3` *(fixed)*

The PR left `pk_dep(:phoenix_kit, "~> 2.0")` on purpose, pending the core
release, and said the conformance test forbids raising it. That pin is now
actively wrong rather than merely conservative.

`put_slug/3` does not exist before core **2.4.0**. Under `~> 2.0`, a host can
legitimately resolve core 2.0–2.3 and **every `Service.changeset/2` raises
`UndefinedFunctionError`** — and it never fails here, because the workspace
always resolves the newest core. This is the same consumer-only failure the
umbrella `AGENTS.md` documents for the old `~> 1.7.x` pins, and core's own
2.4.0 notes tell adopters to pin `{:phoenix_kit, "~> 2.4"}`.

`phoenix_kit_document_creator` (#39) and `phoenix_kit_publishing` already
raised the same floor for the same call. Raising a two-segment floor is not
the three-segment trap the conformance test exists to catch.

**Fix:** pin raised to `~> 2.4`. `core_pin_conformance_test.exs` moved with
it: `@must_admit` is now `2.4.0 / 2.4.7 / 2.5.0 / 2.9.4`, `@must_reject`
gains `2.0.0` and `2.3.0`. The test now guards both directions — too narrow
(a single minor) and too wide (a core lacking the function this module calls).

### IMPROVEMENT - MEDIUM — slug tests missed three branches the form actually hits *(fixed)*

The new file covered romanization, rename-preserves-slug, collision suffix,
and the 160-char cap. Three other `put_slug` cases are load-bearing here
because the admin form exposes `:slug` (`ServiceFormLive`) and the public
URL is `/book/:slug`:

- an explicit slug must win (the form field is not decorative)
- an unromanizable name must not store `""` (core's `:empty` fallback; the
  required-slug error is what the form shows)
- a persisted romanized row must resolve through `get_active_service_by_slug/1`

**Fix:** those three cases added to `service_slug_test.exs`, plus a
ServiceFormLive create through a Cyrillic name so the LiveView path is
pinned, not only the changeset. The long-name test now asserts the suffix
lands at exactly 160 rather than `<= 160`.

### NITPICK — HexDocs `source_ref` did not match this repo's tags *(fixed)*

`docs/0` used `source_ref: "v#{@version}"` but every tag is a bare version
(`0.1.0`, `0.1.1`). That 404s every HexDocs source link. Pre-existing, not
introduced by this PR; corrected on the 0.1.2 release so the new tag and the
docs ref agree. Tag style stays unprefixed, matching `git tag --sort=-creatordate`.

### NITPICK — verbose changeset comment *(left)*

The seven-line comment above `Slug.put_slug/3` is long for production
changeset code. It is also the house style of this adoption series
(`phoenix_kit_document_creator` Template, `phoenix_kit_publishing`
PublishingGroup). Left as-is.

---

## Deliberately not changed

**Trashed services still occupy their slug.** `trash_service/2` only flips
`status`; the unique index is on `slug` with no partial predicate, and
`put_slug` probes the whole table. A trashed row therefore 404s at
`/book/:slug` (`get_active_service_by_slug/1` requires `status: "active"`)
while still blocking a new service from reclaiming the URL. Pre-existing —
the old generator never uniquified either, and the index has always been
global. Reclaiming would need a partial unique index *and* a `:queryable`
that excludes `trashed`; that is a schema version, not a slug-helper swap.

**Unromanizable scripts (e.g. Japanese) still cannot auto-slug.** Core's
`slugify/2` uses `fallback: :empty` because these slugs land in ASCII path
segments. The admin can still type a slug. Documented by the new test;
not this module's to relax.

---

## Verification

- `mix format`
- `mix test` → **105 tests, 0 failures** (test DB already present; `mix test.setup`
  cannot `CREATE DATABASE` under this role because it has no CONNECT on
  `postgres`/`template1`)
- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, format, credo `--strict`, dialyzer)

No browser in this environment; the ServiceFormLive create is the closest
end-to-end stand-in for the public `/book/:slug` URL the slug now feeds.
