# Changelog

All notable changes to **PhoenixKitBookings** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## 0.1.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.1.0 - 2026-08-11

First release. Requires `phoenix_kit ~> 2.0`.

### Added

- **The universal booking module** (#1) — one engine behind both shapes of
  booking: minute-unit services (appointments, classes, resources) and
  day/night services (stays), with `starts_at`/`ends_at` or
  `starts_on`/`ends_on` enforced exclusive by a database CHECK.

- **Services** with availability rules, per-service units, seats/capacity,
  buffers, min notice, max advance, min/max stay, check-in and check-out
  times, flexible durations, approval requirements and a
  `anyone` / `login_required` signup policy.

- **A locked create path.** `Engine.validate_request/5` is pure and advisory;
  `create_booking/4` re-runs it inside a transaction holding
  `SELECT … FOR UPDATE` on the service row — and, when a provider is attached,
  on all that provider's services in `uuid` order, so cross-service provider
  conflicts serialise without deadlocking. Expired holds are pruned inside the
  same transaction and the caller's own hold is excluded from the count.

- **Public booking surface** — a service listing, a booking flow, and a guest
  self-service page reached by a `Phoenix.Token`-signed manage link (90-day
  max age, no account needed) that cancels within the service's cancel window,
  re-checked server-side.

- **Holds, waitlist, pricing, ICS export**, an Oban reminder worker, activity
  logging, and admin pages for services, bookings and settings.

### Fixed before release

- **The migration could not run on a named-schema (`--prefix`) install.** All
  six `CREATE TABLE`s declared the primary key with a bare
  `uuid_generate_v7()`. Core installs that function into whichever schema it
  migrated into, so on a prefixed install `search_path` does not carry it and
  the statement fails outright. Every call is now schema-qualified, which costs
  nothing on a public install; guarded by a test that fails on a bare call.

- **The migration prefix was interpolated into DDL unvalidated.** It is now
  checked against an identifier pattern and raises otherwise, matching core and
  the other module-owned chains.
