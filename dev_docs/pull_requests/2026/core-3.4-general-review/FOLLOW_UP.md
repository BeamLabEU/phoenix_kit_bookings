# Follow-up — general review on the move to core 3.4

2026-11-06: how Claude's findings (`CLAUDE_REVIEW.md`) were resolved. This is not a PR folder.

- **Fixed:** every BUG, IMPROVEMENT and NITPICK in the review. Each behaviour fix has a test. These have none of their own: the
  gettext wrapping, the form `id`s (the `missing_form_id` warnings are gone), `PGDATABASE` / `PGPOOL`, the
  `test_helper.exs` stop (seen once by hand, against a database at V217), `migrated_version_runtime/1`'s `catch :exit`, the
  provider select reading once at mount, and the docs.
- **Left, recorded:** the "Left, on purpose" list.

## Dependencies

`phoenix_kit` 2.64.1 → 3.4.0 (floor `>= 3.4.0 and < 4.0.0`), `phoenix_live_calendar` floor `~> 0.5` (locked 0.5.1, unchanged),
and `mix deps.update --all` for the rest. No new migration: the chain stays at V2.

## For hosts

- `mix phoenix_kit.update`. Core's own rule applies: a host below core V225 passes through 2.65.0 first.
- **The availability change is visible.** A minute service with only closed rules was bookable on no day and now opens on
  every other day; a closed weekday beside an open rule now really closes.
- **A stay on a service with blank `max_stay` now stops at 366.** Set `max_stay` above that where longer stays are real.
- Peer limits need `connect_info: [:peer_data, ...]` on the host's socket. Without it only the address limit applies.
