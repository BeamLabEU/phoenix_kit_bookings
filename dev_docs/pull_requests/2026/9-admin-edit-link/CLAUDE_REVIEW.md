# PR #9 — Add an Edit service link to the public booking page for managers

**Author:** timujinne · **Merge:** 7dfc8e6 · **Reviewer:** Claude · **Scope:** `Web.Public.BookLive`, `test/support/test_layouts.ex`, `public_live_test.exs`

`BookLive.handle_params/3` now calls `AdminEditHelper.assign_admin_edit/3` for a viewer who passes
`Policy.can_manage?/2`, and hands `admin_edit_url` / `admin_edit_label` to `LayoutWrapper.app_layout`
through `module_assigns`. Seven tests cover the matrix (site manager, owner, non-owner, wrong module
key, owner without the key, anonymous, unknown slug).

## Verdict

Correct, no blocking findings. Nothing in the code needed changing; one doc gap was filled.

## What was checked against core

- **Gate composition.** The helper's gate is `Scope.can_access_admin_area?/1` + `has_module_access?(scope, "bookings")`.
  `Policy.can_manage?/2` narrows that to site-wide managers and the service's owner. A base-key holder
  who does not own the service gets nothing (tested), which matches `ServiceFormLive`'s own
  `can_manage?` redirect, so the link never points at a page that bounces the viewer.
- **`module_assigns` is not a permission bypass here.** Core's `LayoutWrapper` docs say a
  `module_assigns` value is NOT run through the helper's gate. It is safe in this PR because the
  assigns exist only after the helper approved them (absent otherwise, so `assigns[:admin_edit_url]`
  is `nil` and core's `resolve_admin_edit/1` ignores a non-binary url).
- **Core floor (`>= 2.38.0`) still holds.** Verified against the hex tarballs: `AdminEditHelper` with
  the `:permission` option ships in 2.38.0; `resolve_admin_edit/1` and the dedicated attrs arrive only
  in 2.62.0, but before that `app_layout` already flattens `module_assigns` into the host layout's
  assigns, so the `module_assigns` route (rather than the 2.62 attrs) is what keeps older cores
  working. Do not "simplify" it to `admin_edit_url={...}` attrs without raising the floor.
- **Trigger reality check.** Only active services reach the assign (`get_active_service_by_slug/1`), so a
  manager does not see Edit on an inactive/trashed offer's public URL; that is fine, the admin list is
  the way in.

## Findings

### NITPICK — stale Edit assigns if the page were ever patched between services
`assign_admin_edit/2` adds assigns but never clears them: the helper returns the socket unchanged when
denied, and the `nil`-service branch of `handle_params/3` does not reset them. If a `live_patch` ever
moved one `BookLive` process between slugs, a manager's link would survive onto a service they cannot
edit. Not reachable today: nothing under `web/public` patches, and a navigate to another slug mounts a
fresh LiveView. **Not fixed** (speculative defence); revisit if the page gains in-place slug switching.

### NITPICK — `"Edit service"` has no translation
LiveViews use core's `PhoenixKitWeb.Gettext`; the msgid is extracted but core ships no catalogue entry,
so non-English admin viewers see English until a translation pass. No action; tracked by the existing
gettext TODO.

### NITPICK — doc gap (fixed)
AGENTS.md did not mention the link or why it uses `module_assigns`. Added to the Public flow section.

## Tests

`public_live_test.exs`: 20 tests, 0 failures with the integration DB present. The new tests are
meaningful: the `Test.Layouts.public` marker proves the full socket assign → `module_assigns` →
`app_layout` → host layout path, and the `cached_roles` shim comments explain why `fake_scope`'s
MapSet roles don't satisfy core's `can_access_admin_area?/1`.
