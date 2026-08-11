# PR #1 — Add the universal booking module

**Author:** mdon · **Branch:** `main` (fork) · **Reviewed:** 2026-08-11

The whole module: 8,712 lines across schemas, engine, contexts, admin +
public LiveViews, Oban reminder worker, ICS export, and 96 tests.

A first-module review can't be exhaustive at this size, so it was aimed at the
things that are expensive to fix after release: the concurrency model, the
public (unauthenticated) surface, migration/prefix conformance, and whether the
module sits correctly in the ecosystem.

## What holds up

**Double-booking.** The design is right, and it is the part most modules get
wrong. `create_booking/4` treats `Engine.validate_request/5` as advisory and
re-runs it inside a transaction that takes `SELECT … FOR UPDATE` on the service
row — and, when a provider is attached, on *all* that provider's services in
`uuid` order, so cross-service provider conflicts serialise without deadlocking.
Expired holds are pruned inside the same transaction, and the caller's own hold
is excluded from the occupancy count. Rejections come out via
`repo().rollback/1`, so a failed capacity check cannot leave a row behind.

**Guest manage links.** `/bookings/manage/:token` resolves through
`Phoenix.Token.sign/verify` against the host endpoint's `secret_key_base`, with
a 90-day `max_age` — not an enumerable id. `token_endpoint/0` deliberately
avoids falling back to core's compiled-but-not-running `PhoenixKitWeb.Endpoint`.
The cancel handler re-checks `cancellable_by_customer?/2` server-side rather
than trusting the hidden button.

**Ecosystem conformance.** `extra_applications: [:logger, :phoenix_kit]` is
present (without it auto-discovery silently 404s every route); the core pin is
a two-segment `~> 2.0` with the conformance test guarding it; all six schemas
`use PhoenixKit.SchemaPrefix`; `version/0` reads the app spec so it cannot
drift from `mix.exs`; and every table is namespaced `phoenix_kit_bookings_*`
with **zero** overlap against core's `ExpectedSchema` — so the AGENTS.md rule
about not re-creating a table core owns is satisfied. `phoenix_live_calendar`
is a published Hex package, so the no-git/path-deps rule holds.

---

## BUG - HIGH — the migration breaks every named-schema (`--prefix`) install

All six `CREATE TABLE`s declared the primary key as:

```sql
uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
```

Unqualified. Core installs `uuid_generate_v7()` into whichever schema it
migrated into, so on a `--prefix`ed install the function lives in that schema,
`search_path` does not carry it, and the `CREATE TABLE` fails outright — the
module cannot install at all. Core's own chain qualifies every call
(`Helpers.uuid_v7_call/1`, `#{p}uuid_generate_v7()`), and core's AGENTS.md
names this as a rule.

It works on every `public` install, which is exactly why it survives review.

**Fixed.** `up/1` now builds `uuid_default = uuid_v7_call(prefix)` and
interpolates it into all six tables. Qualifying costs nothing on a public
install.

**Test:** `schema_prefix_conformance_test.exs` gained
`"no migration statement calls uuid_generate_v7() unqualified"`. The existing
test in that file guarded the *runtime* half of prefix support
(`use PhoenixKit.SchemaPrefix`) and had no view of the DDL half, which is where
the bug was. Mutation-verified: restoring one bare call fails it.

## BUG - MEDIUM — the migration prefix was interpolated into DDL unvalidated

`normalize_prefix/1` was `opts[:prefix] || "public"` with no check, and the
result goes straight into `CREATE TABLE #{prefix_str}…`. Core validates its own
prefix (`Helpers.validate_prefix!/1`) and so does phoenix_kit_legal's chain;
this module was the outlier, and it is the last hop before the database.

Reachable only by a host operator passing `--prefix`/config, not by an end
user, so it is hardening rather than a live hole — but it is one line.

**Fixed.** `validate!/1` enforces `^[a-zA-Z_][a-zA-Z0-9_]*$` and raises
`ArgumentError` otherwise; `nil` still means `"public"` and is left alone.
Covered by `"the migration refuses a prefix that cannot be safely interpolated"`.

## Release blocker resolved — `mix precommit` did not pass as submitted

`mix deps.unlock --check-unused` failed on eight stranded lock entries
(`igniter`, `sourceror`, `spitfire`, `rewrite`, `owl`, `glob_ex`, `ex_ast`,
`text_diff`) — the transitive set core 2.0 dropped, exactly the failure
AGENTS.md warns about. Cleared with `mix deps.unlock --unused`; `mix.lock` is
part of this merge.

---

## Accepted as-is

`ServicesLive.mount/3` queries (`list_public_services/0`), so it runs on both
the dead render and the connected mount. Moving it to `handle_params/3` would
not help — that runs on both too. The only real fix is a `connected?/1` guard,
which would leave the public "Book with us" listing empty in the first paint
and in every no-JS/crawler fetch. For a public catalogue page that is the wrong
trade. `BookingWidgetLive` queries in `mount/3` for the same reason and has no
`handle_params/3` available at all (it is nested).

---

## Verification

- `mix test` — 25 tests, 0 failures (71 `:integration` excluded).
- `mix precommit` (compile-as-errors + unused deps + format + credo --strict +
  dialyzer) — clean, exit 0.
- ⚠️ **No PostgreSQL in the review environment.** 71 of 96 tests did not run,
  and they are the ones that matter most here: the locked-create concurrency
  path, the LiveView flows, and the migration itself. The prefix fix above is
  in particular **not** exercised by a real prefixed install — that needs a DB
  run, ideally the equivalent of core's
  `test/integration/prefix_migration_test.exs`, before this is published to Hex.
  The unit half (engine, pricing, policy, conformance) is fully green.

## Left for a follow-up

The module has no prefixed-install integration test of its own. Core's
`prefix_migration_test.exs` is the pattern; given this PR shipped a bug that
*only* appears under a prefix, that test is the highest-value thing to add next.
