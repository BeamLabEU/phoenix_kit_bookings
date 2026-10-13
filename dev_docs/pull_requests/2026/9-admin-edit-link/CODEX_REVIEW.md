# PR #9 — Add an Edit service link to the public booking page for managers

**Author:** timujinne · **Merge:** 7dfc8e6 · **Reviewer:** Codex · **Date:** 2026-10-13

Reviewed the current 0.1.5 tree at 1d64790, including PR #9, the subsequent
dependency update b9319dc, and Claude's review. The fresh-mount permission
matrix is correct. The navigation findings below were reproduced and fixed
locally. No version, changelog, or release changes were made.

## Findings

### BUG - MEDIUM — Edit links survive a client patch to another service

`BookLive.handle_params/3` retained the previous Edit assigns when the new
service was unowned or missing. A patch from an owned service to an unowned
one displayed the first service's editor link. This is a stale navigation
target, not an authorization bypass: the editor still checks permissions.

Claude correctly noticed the retained assigns but classified the problem as
speculative because the module has no patch links. LiveView already accepts
client patches between routes handled by the same LiveView. The regression
uses `render_patch/2` on the existing router and needs no new navigation UI.
See the [LiveView lifecycle and navigation documentation](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#handle_params/3).

Clearing the assigns alone did **not** fix the rendered link. Core's layout
flattens `module_assigns` with `Map.put_new/3`, which does not update change
tracking. Its newer Edit resolver only marks binary URLs as changed; a cleared
URL therefore leaves the previous HTML in the host layout. Two regression
tests still failed after the initial socket-only fix.

**Fix:** clear both Edit assigns before each URL reload, and use a small
`booking_layout/1` adapter to mark the flattened Edit keys as changed when
`module_assigns` changes. The adapter delegates to core and retains the
existing `module_assigns` API. Tests cover owned → unowned → owned and
active → missing navigation, asserting the rendered link rather than only
the socket assigns.

### BUG - MEDIUM — Flow reloads abandon holds and accumulate subscriptions

`BookingFlow.assign_flow/4` resets `hold_uuid` and subscribes to the next
service without releasing the old hold or unsubscribing from the previous
service. On a client patch, the first hold continues blocking capacity until
its five-minute expiry. Patching to a missing slug retains the old resources;
a subsequent booking notification calls `refresh_pick/1` with `service: nil`
and crashes the LiveView.

**Fix:** `BookingFlow.clear_flow/1` releases the hold and subscription before
`BookLive` reloads its service. Termination uses the same cleanup. Booking
notifications refresh only the currently loaded service, and unavailable
pages ignore queued booking events. The integration test creates real holds
on two services, checks their removal and actual PubSub registrations, then
delivers a queued notification and picker event after navigation to a missing
slug. A separate test checks notifications on an initially missing page.

### IMPROVEMENT - MEDIUM — Full-suite redirect assertions assume a locale prefix

Before any changes, `mix test` ran the integration suite and failed three
admin tests: two editor redirects and one settings denial. The updated core
generates bare `/admin/...` URLs with Languages disabled, while the assertions
hardcoded `/en/admin/...`. Claude's public-only test run did not expose these
failures.

**Fix:** expected editor redirects now use `Paths.admin_service_edit/1`, and
the core admin redirect uses `Routes.path/1`, matching their respective
production callers. The test router still accepts the existing localized
test entry URLs. Production routing was unchanged.

## Independent checks

- The service policy and core helper gates remain composed; `module_assigns`
  contains only values produced by the gated helper. Added coverage for a
  site-wide manager with permissions and no system role, supplementing the
  existing owner-role and base-permission tests.
- Downloaded the [PhoenixKit 2.38.0 Hex tarball](https://repo.hex.pm/tarballs/phoenix_kit-2.38.0.tar)
  and inspected the actual helper and layout-wrapper source. The helper's
  `:permission` option and parent-layout `module_assigns` flattening are
  present. The dependency floor remains unchanged.
- Ran all 25 public tests in an isolated Mix process with those two 2.38.0
  source modules loaded over the current installed modules: **25 tests,
  0 failures**. This checks compatibility with those components on the
  current dependency stack, not the entire module against a fully pinned
  2.38.0 dependency graph.
- The English-only `Edit service` label still follows the repository's core
  Gettext convention. No translation catalogue was added in this review.

## Validation

- Baseline full suite: **148 tests, 3 failures**; integration DB available.
- Added navigation regressions before fixes: **25 public tests, 4 failures**
  (stale links, abandoned hold, and missing-service notification crash).
- Final full suite: **153 tests, 0 failures**; integration DB available and
  no integration-exclusion banner.
- Public tests with the 2.38.0 helper/layout source: **25 tests, 0 failures**.
- `mix precommit`: **passes** (warnings-as-errors compilation, unused-lock
  check, Hex audit, formatting check, strict Credo, and Dialyzer).

Known test warnings about support-module redefinition and missing form IDs
remain. No broader claim of complete bug absence is made outside the reviewed
paths and exercised tests.
