# PR #7 Review: Add a notify option to create, confirm and cancel a booking silently

**Author:** Max Don (mdon)
**Reviewed:** 2026-09-21
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_bookings/pull/7
**Merge:** `2202940` (`8522d1a` on the fork)
**Verdict:** APPROVED with follow-up. Already merged; the Policy gap is
closed and ships in 0.1.5.

---

## The change

`create_booking/4`, `confirm_booking/2` and `cancel_booking/2` accept
`notify: false`. It suppresses the customer's lifecycle email and, on
create, the reminder job. This is meant for importers and for bookings an
operator takes by phone. Validation, capacity, pricing, the activity log
and PubSub are all unchanged. A quiet cancel still notifies the waitlist.

---

## What holds up

**It only goes quiet on an explicit `false`.** `notify?/1` is
`Keyword.get(opts, :notify, true) != false`, so `nil`, `"false"`, or a
misspelled value keeps confirmations on. That is the safe default for a
flag that stops mail. The "only an explicit false" test covers it.

**The option is gated after the transaction commits.** `after_create/3`
runs outside `repo().transaction/1`, and `log_and_broadcast/3` still runs
before the `notify?` check. A silent booking still shows up in the admin
list live and still appears in the audit trail.

**Every customer-facing message is covered.** `Notifier.booking_created/2`
(both the pending and confirmed variants), `booking_confirmed/2` and
`booking_cancelled/2` only email `booking.customer_email`. No admin or
operator notice is suppressed by accident. The reminder is scheduled only
at create, and the worker re-checks status when it fires. A silent cancel
of a loudly created booking therefore needs no job cleanup.

**The waitlist decision is right.** The people on the waitlist asked to be
told when the dates free up. Who cancelled, and whether that customer was
emailed, is not their concern. `tap_waitlist/1` stays outside the gate.

**The tests would catch a regression.** The suite starts a real Oban in
`:manual` mode, and the control test shows that a reminder is visible when
it should be. Without that, `ReminderWorker.schedule/2` hits its rescue,
and `refute_enqueued` would pass whether or not the option worked. The
module is `async: false`, and ExUnit runs sync modules after the async
ones, so no async test's `schedule/2` can land in this named `Oban`
instance.

---

## Findings

### IMPROVEMENT - MEDIUM: `Policy.confirm_booking/2` could not pass `notify:` *(fixed)*

AGENTS.md makes `Policy` the only authorization surface for admin code:
every admin mutation goes through it, never through `Bookings` directly.
`Policy.cancel_booking/3` already accepted `opts` and appended them to
`actor_opts/1`. `Policy.confirm_booking/2` had no `opts` argument. An
admin screen, or anything else that follows the convention, could cancel
quietly but could not approve quietly. The only way to approve quietly
was to call `Bookings` directly, bypassing authorization.

**Fix:** added `Policy.confirm_booking/3` with `opts \\ []`, appended the
same way as in cancel. `actor_opts` comes first, so a caller cannot
override `actor_uuid` (`Keyword.get` returns the first match). New tests
in `notify_test.exs` cover confirm and cancel through `Policy` with
`notify: false`, and check that a `Policy` confirm without the option
still sends the approval email.

### NITPICK: a quietly created booking never gets a reminder, even if later confirmed loudly *(not changed)*

Reminders are scheduled only in `after_create/3`. Take a `require_approval`
booking imported with `notify: false` and later approved normally. The
customer gets "Booking approved" with the `.ics`, but no reminder. The
PR's docs describe this case: callers that want a reminder call
`ReminderWorker.schedule/2` themselves. Scheduling a reminder on confirm
would give every normally created pending booking a second job, unless
the worker is also made unique per `booking_uuid`. That is a behaviour
change beyond this PR, so it is left as documented.

### NITPICK: the audit log does not record that the customer was not told *(not changed)*

The activity metadata is `service_uuid` + `status` for both loud and quiet
operations. An operator asking "why didn't the guest get a cancellation
email?" cannot answer that from the log. A `"customer_notified" => false`
key would be cheap to add. It is not added here because the metadata shape
is a stated convention and no test reads activity rows yet. Worth doing
together with the first activity assertion in the suite.

---

## Not changed

- There is no admin UI toggle for "don't email the customer". The PR
  targets server-side callers. Adding a checkbox to `BookingsLive` is a
  product decision, and the `Policy` fix above makes it a template-only
  change when it comes.
- `71667de libs` (lock bump: phoenix_kit 2.34.0, etcher 0.16.0, fresco
  0.12.2) landed with the PR. The gate and the full suite pass on it.
