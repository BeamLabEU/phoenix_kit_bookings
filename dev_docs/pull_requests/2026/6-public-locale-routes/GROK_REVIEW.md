# PR #6 Review — Fix public booking pages 404ing when Languages is enabled

**Author:** Max Don (mdon)
**Reviewed:** 2026-09-20
**Reviewer:** Grok (grok-4.6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_bookings/pull/6
**Merge:** `54eec3e` (`37f3268` on the fork)
**Verdict:** APPROVED with follow-up — already merged; locale-validation gap
closed and released as 0.1.4

---

## The change

`Web.Routes.generate/1` registered the three public LiveViews only under
the bare URL prefix. `PhoenixKitBookings.Paths` builds every public link
through `PhoenixKit.Utils.Routes.path/1`, which inserts a locale segment
as soon as core's Languages module is on and the target is not the
prefixless primary. The module therefore generated its own 404s —
including `public_manage_url/1`, the only cancel path a guest without an
account has.

The fix emits both shapes inside the one `:phoenix_kit_bookings_public`
`live_session` (localized first, then bare), matching core's
`build_live_surface/5`. Sharing the session keeps a front-end locale
switch on the WebSocket. Duplicate `:as` names are safe because hosts
compile the router with `helpers: false`.

The new `test/phoenix_kit_bookings/web/routes_test.exs` compiles a
host-shaped router from `generate/1` itself (`Module.create/3` so the
router imports survive). That is the right test: `Test.Router` still
hand-writes the public paths, which is how 0.1.3 shipped the bare-only
table. Against the unmodified module the new test fails on
`/<prefix>/et/bookings`.

---

## What holds up

**The diagnosis is real.** `Paths.public_index/0` is `Routes.path("/bookings")`
and `build_path_with_locale/3` prefixes every non-primary locale. Admin
tabs ride core's dual-scope admin surface, so they never showed this;
only `route_module/0` → `generate/1` did.

**Declaration order does not re-open the shop/`locale="admin"` bug.**
Core's `phoenix_kit_routes/0` splices `module_public_routes` *after*
the admin and authenticated surfaces and comments that a `generate/1`
emitting `/:locale/...` would re-open the collision. Bookings' paths
are specific (`/bookings`, `/book/:slug`, `/bookings/manage/:token`),
not catch-alls, and `/<prefix>/admin/bookings` is already claimed by
the admin bare route (`/<prefix>/admin/bookings`) before this block
runs. `/<prefix>/en/admin/bookings` is claimed by the admin localized
route. Left as a comment on `generate/1` so a future catch-all does
not walk into it.

**LiveView `handle_params` already tolerate the extra key.**
`BookLive` matches `%{"slug" => slug}`, `ManageLive` matches
`%{"token" => token}`, `ServicesLive` ignores params. A localized hit
adds `"locale"` and still matches. Locale assigns on live navigation
come from core's `:current_page` `handle_params` hook, attached by
`:phoenix_kit_mount_current_scope`.

**The test harness change is the actual regression lock.** Compiling
`generate/1` rather than asserting against `Test.Router` is the thing
that would have caught 0.1.3.

---

## Findings

### BUG - MEDIUM — localized routes skipped `:phoenix_kit_locale_validation` *(fixed)*

The PR claims to mirror `build_live_surface/5`. Core's two defences for
an unconstrained `:locale` segment (Phoenix.Router silently drops any
regex "constraint") are:

1. declaration order — literal-prefixed surfaces first;
2. the `:phoenix_kit_locale_validation` pipeline plug
   (`validate_and_set_locale/2`), which redirects invalid, disabled, and
   dialect URLs and rejects reserved segments (`admin`, `users`,
   `dashboard`, …).

`generate/1` kept `pipe_through([:browser, :phoenix_kit_auto_setup])`
on both scopes. The LiveView `on_mount` still *sets* Gettext from a
valid base code, so a well-formed `/et/book/slug` renders in Estonian.
What it does not do is what every other PhoenixKit public page does:

- `/xx/bookings` 200s instead of redirecting to the default locale;
- a valid-but-disabled language code is applied (`valid_base_code?`
  without `locale_allowed?`);
- `/en-GB/bookings` is not canonicalized to the base code.

The whole PR exists because Languages was turned on. Shipping the
localized scope without the plug that makes unconstrained `:locale`
safe is the incomplete half of the same change.

**Fix:** both scopes now pipe through
`:phoenix_kit_locale_validation` (the pipeline `phoenix_kit_routes/0`
always defines before splicing `generate/1`). The host-shaped test
router stubs it, and `route_info/4` asserts it is on the pipe of both
URL shapes.

### IMPROVEMENT - MEDIUM — host `extra_live_session_on_mount` never ran *(fixed)*

Core prepends `config :phoenix_kit, extra_live_session_on_mount:` to
every surface `build_live_surface/5` emits (per-domain default-language
hooks and similar). Bookings has its own `live_session`, so those hooks
never ran on `/bookings`. Pre-existing — the session predates this PR —
but the PR restructured the session to match `build_live_surface/5` and
still omitted this.

**Fix:** `generate/1` prepends the same env list at expansion time. The
host router's `__mix_recompile__?/0` already invalidates when that
config changes, so the expansion is re-run.

### IMPROVEMENT - MEDIUM — "both shapes reach the same LiveView" did not check the LiveView *(fixed)*

The third test fetched `route_info/4` for both shapes, `refute`d the
route strings (trivially different because of `:locale`), and re-asserted
both paths exist. It never inspected `plug_opts`. A localized scope
pointing at a different module, or at no LiveView, would still pass.

**Fix:** assert `plug_opts` is the same LiveView on both shapes for all
three pages, that `:locale` binds on the localized shape, that neither
shape is a catch-all, and that a root-mounted `generate("/")` still
routes `/bookings` and `/et/bookings` (`"#{prefix}/:locale"` must not
become `"//:locale"`).

### NITPICK — the three `live` calls were copy-pasted *(fixed)*

Two lists of the same three routes. Extracted to `public_live_routes/0`
so they cannot drift, the same shape core uses for `route_macro` inside
`build_live_surface/5`.

---

## Not changed

- `Test.Router` still hand-writes public paths. That is the LiveView
  test double (test layout, test `on_mount`, no core pipelines). Routing
  of what `generate/1` actually emits lives in `routes_test.exs` on
  purpose — wiring Test.Router through `generate/1` would re-couple the
  two and recreate the 0.1.3 gap.
- `ServicesLive` still queries in `mount/3`. Pre-existing, not this PR.
- Core's comment that "every module's `generate/1` currently emits
  root-scoped literal routes" is now stale for this package. That is a
  core-docs issue; the ordering invariant still holds here.
