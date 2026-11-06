# General review on the move to core 3.4

**Not a PR.** A whole-module review made when the core floor moved from `>= 2.38.0 and < 3.0.0` to
`>= 3.4.0 and < 4.0.0`, on top of `3b7df71`. **Reviewer:** Claude · **Date:** 2026-11-06 · **Scope:** all of `lib/`, the
test setup, and the parts of `phoenix_live_calendar`, core and staff this module leans on.

## Verdict

The module runs on core 3.4 unchanged: 152 of 153 tests passed before any fix, the one failure being the pin test. The
trouble was in the module itself. The BUGs below were reproduced by a failing test first. The ones that could not fail
first (`bookable_slots/6` is a new arity, the rate limit is new code) were proved by undoing the fix and watching the
test fail. `FOLLOW_UP.md` lists what has no test of its own.

## BUG - HIGH

**One blackout date closed a minute service on every day.** `lib_availability/1` mapped rules one to one, and the lib
answers no window for a day no rule mentions. So an always-open service with one holiday added had no bookable day left.
`DayEngine` handled this correctly and its test pins it, so the two engines disagreed. Same for a lone closed weekday.

**A closed weekday did nothing beside an open rule.** The lib reads a closed window only on a date override. "Open Mon–Fri,
closed Wednesday" stayed open on Wednesday on a minute service, with no sign of it in the admin. `DayEngine` closes it.

**A public stay had no end.** `max_advance` bounds the start only, so with `max_stay` blank (the form says "blank =
unlimited") a guest could send `ends_on: 9999-12-31`. One booking took a room for the rest of the calendar, and each
check walked about three million dates, inside the row lock on the locked create. Free-form minute services already stop
at 366 days; day services now do too.

**`create_booking/4` trusted the caller's struct.** It locked the service row and validated capacity against it, but
judged the status, the signup policy and the approval rule from the struct the page had mounted with. A service trashed,
deactivated or moved behind a login while a visitor typed still took the booking, and one switched to approval got a
confirmed booking. A service deleted meanwhile raised.

**Lifecycle writes had no guard.** `confirm_booking/2` and `cancel_booking/2` wrote from the struct they were given.
Approving what had just been cancelled brought it back after its capacity could have been resold, and a second cancel from
an open tab mailed the customer again and overwrote `cancelled_at`.

**A deactivated account passed the widget's login gate.** `BookingWidgetLive` used `Auth.get_user/1`, which answers for a
deactivated account, so `login_required` held only for accounts that never existed. Core's
`assign_embedded_current_user/2` also carries the managed-organization rules.

## BUG - MEDIUM

**Slot grids read the wrong clock.** `TimeSlots.bookable_slots/4` compares the UTC clock with wall clocks in the site frame
and has no past check. So past slots of today were offered and then refused on click, `min_notice` was off by the site's
offset, and west of UTC free slots were hidden: at 10:00 in New York with an hour's notice, nothing showed until 16:00.
`bookable_slots/6` now judges all three from the site's clock.

**Manage links died 90 days after signing.** A stay booked four months ahead could not be cancelled from its confirmation
mail for the last month, and day bookings get no reminder to bring a fresh link. A link now lives until 90 days after the
booking ended.

**The admin list hid the newest bookings.** Every filter sorted oldest first under a limit of 200, so past 200 rows a new
confirmed booking never appeared. Lists reaching into the past now read newest first and say when they are cut. Timed and
dated bookings also sort together now.

**Fixed slots were only as fixed as the browser.** The lib does not check the grid, so a hand-made `pick_slot`, or
`pick_free` on a fixed-slot service, could book 10:30 on an hourly grid and take two slots.

**A unit went back into use inside its buffer.** `pick_unit/3` read the raw range, so a room with 30 minutes of cleaning was
handed straight to the next booking with another room free.

**The provider read stopped short of the request's buffers.** The lib widens the request, but the read did not reach that
far, so a neighbour inside the buffer was never loaded.

**A closed rule on a minute service demanded times** it then ignored, against the form's own "a closed rule blocks the day".

**The provider select.** It labelled a person with no name of their own "Person 0197abcd", though their account has a
name, and it read the database twice on every render, which is every keystroke of the form.

**Waitlist edges.** A timed booking across midnight notified only its first date. A past date was accepted. `get_by/2`
raised for good on an address with two open rows, which a double submit can make, as nothing unique stands behind it.

**`submit_details` ignored the step.** Replayed after `:done` it booked again on a pooled service, and before a pick it
crashed the page.

## IMPROVEMENT - HIGH

**Public forms were an open mailer.** A guest form mails any address, with a typed name in the body, without limit.
`RateLimit` now caps a booking or a waitlist join per address and per peer, per hour.

**`doctor` and `repair` could not see these tables.** They are in no core manifest, and 21 sibling modules already supply
`expected_schema/0`. Added, generated by core's script, with a test that fails when it drifts.

**`test_helper.exs` hid a broken build.** A schema that failed to build excluded the integration suite and passed, which
staff fixed in 0.11.1. It now stops the run; only an unreachable database excludes.

## IMPROVEMENT - MEDIUM

- `PGDATABASE` and `PGPOOL` in `config/test.exs`, as the siblings have.
- The Edit link rides `app_layout`'s attrs and `booking_layout/1` is gone, as the PR #9 review said to do once the floor
  allowed it.
- `reserved_route_prefixes/0`, so Publishing's catch-all leaves `book` and `bookings` alone.
- Holds no longer reload every admin list, and a released hold gives the slot back to open pickers.
- `BookingFlow` had no gettext at all. Its strings are extractable now.
- Unit-tracked services listed their `seats` column instead of their units.
- `id`s on every form, which LiveView needs to recover one on reconnect.

## BUG - LOW

- `visible_services/2` read a scope with no user as "no filter": it failed open.
- Owning a service outlived the base key.
- Restoring from the trash went past the per-user cap.
- `migrated_version_runtime/1` swallowed an invalid prefix into "not installed", and had no `catch :exit`, so a dead pool
  would have crashed `mix phoenix_kit.status`.
- `down(version: 2)` on a V2 database dropped the V2 column.

## NITPICK

- `^...$` in the email and slug formats lets a trailing newline through. Now `\A...\z`.
- `.ics` lines ran past RFC 5545's 75 octets. Now folded.
- Stale docs: "three tables", `~> 0.1.4`, `~> 2.14`, "least-loaded".

## Checked, nothing wrong

- **`terminate/2` does release holds.** It is only skipped on a crash: a normal disconnect stops the channel from a
  callback, which runs it.
- **The generated routes are valid on 3.4**: `:phoenix_kit_locale_validation`, `:phoenix_kit_auto_setup` and
  `:phoenix_kit_mount_current_scope` all exist. The test router does not prove that; core's source does.
- **`from_email` / `from_name`** are still core's keys, and `Oban.insert/1` matches core's own use.

## Left, on purpose

- **Holds are not rate limited.** A bot with many sockets can hold seats for five minutes at a time. A hold mails nobody.
- **Two visitors on the last seat** each see the other's hold, so the first to submit is refused and frees it.
- **Reminders go to `pending` bookings** too, worded as if confirmed. Whether they should is a product call.
- **Changing `time_unit` on a service with bookings** leaves them in the old shape, unseen by the new engine. It needs a
  decision: refuse, or migrate.
- **A cancellation carries no `.ics`**, so the event stays in the customer's calendar.
- **Customer details stay after a user is deleted** (`user_uuid` goes to NULL, the name and email remain). There is no
  `before_user_delete/1`. Retention is the site owner's decision.
- **A partial-day closure is not possible.** A closed rule closes the whole day, because the lib ignores a closed window's
  times. The form now says so.
- **`phoenix_live_calendar`:** `TimeSlots.bookable_slots/4` should take `now:`. Then `Engine` can stop handing it zeros.
- **No `priv/gettext` catalogue yet,** and `Format` and `Notifier` are still plain English.
