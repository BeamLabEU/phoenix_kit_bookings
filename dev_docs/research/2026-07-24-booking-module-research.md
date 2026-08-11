# phoenix_kit_bookings — pre-implementation research

Date: 2026-07-24. Compiled before any code exists in this repo (upstream is a
2-line README, single "Initial commit" by ddon, 2026-07-21). Three research
tracks: (1) the booking layer already inside `phoenix_live_calendar` +
`phoenix_kit_calendar`, (2) PhoenixKit ecosystem integration points, (3) the
feature landscape of existing booking/scheduling products.

---

## 1. What already exists in this workspace

### 1.1 `phoenix_live_calendar` ships a complete in-memory booking *rules engine*

The lib is explicitly layered; Layer 3 = booking constraints, pure Elixir, no
DB. **Do not rebuild any of this:**

- **`BookingConfig`** (`lib/phoenix_live_calendar/booking_config.ex`) — a
  Cal.com-EventType-style rules template: `duration` (default 30),
  `min_duration`/`max_duration` (free-form bookings), `slot_interval`,
  `buffer_before`/`buffer_after`, `min_notice` (minutes), `max_advance`
  (days), **`seats`** (per-slot capacity, 1 = exclusive), `availability`
  (list), `timezone`. Helpers: `effective_slot_interval/1`,
  `total_blocked_time/1`.
- **`Availability`** (`availability.ex`) — one struct models weekly rules
  (`days_of_week` ISO 1–7) AND date overrides (`date` set → wins over
  recurring) AND per-resource scoping (`resource_id`) AND block-outs
  (`available: false`). `windows_for_date/3` resolves everything.
- **`Utils.Constraints.validate_booking/5`** — the full validation pipeline:
  `:invalid_range`, `:too_short`/`:too_long`, `:in_past`,
  `:insufficient_notice`, `:too_far_ahead`, `:outside_availability`
  (**cross-midnight correct** — splits the range into per-day segments,
  every segment must fit a window), `:overlap` (buffer-expanded, only vs
  `overlap: false` events), `:at_capacity` (seat counting). Pure & advisory —
  nothing locks.
- **`Utils.TimeSlots.bookable_slots/4`** — slot generation: returns
  `[{start, end, :available | :unavailable | :booked}]` per date, applying
  notice/advance/overlap/seats. Ready to render on a picker.
- **`Resource`** struct + resource/timeline views (resources as
  columns/rows) — rooms/people/equipment, hierarchical (`parent_id`),
  events link via `resource_id`/`resource_ids`.
- **UI gestures** on `CalendarComponent`: `on_range_select` (drag a slot),
  `on_time_select`, `on_event_drop`/`on_event_resize` (reschedule),
  `on_date_range_change`. `Event.status` already has the booking vocabulary:
  `:confirmed | :tentative | :cancelled | :pending_approval | :no_show`.
  `DayMarker` (blackout dates/reduced hours), `Layer` (per-provider
  toggles), `Heatmap` (availability density), `MiniCalendar`, `Widgets`.
- **Ecto store (Layer 4)** persists **events + resources only**
  (`phoenix_live_calendar_events`/`_resources`, versioned migrations V1–V2).
  There are **no tables** for BookingConfig, Availability, or bookings.

**What the lib deliberately does NOT have** (= this module's job):
persistence of the booking domain, customer/attendee capture, lifecycle
state machine, double-book locking (race protection), policy enforcement
(cancel/reschedule windows as stored policy), notifications/ICS, payments,
a public unauthenticated booking page.

### 1.2 `phoenix_kit_calendar` is the PhoenixKit integration blueprint

The reference consumer; copy its pattern set wholesale:

- **Authorization-in-context**: every `Events` fn takes `scope` first;
  `can_view?/can_edit?` via `Scope.can?/2`; **load-then-authorize** against
  the persisted owner (`reload_and_authorize/3`); owner_uuid **never cast
  from attrs** (explicit arg + `put_change`). `safe_get` rescues
  `CastError` on forged ids.
- **Sub-permissions**: `permission_metadata/0` with `sub_permissions:`
  (`%{key: "view_others", label:, description:}`) → dotted keys
  (`calendar.view_others`) in core role permissions; sub-implies-base
  enforced by core; checked in the context, composed with
  `Permissions.feature_enabled?("staff")` for cross-module gating.
- **Timezone model**: storage always true-UTC (`utc_datetime` pair); all-day
  = separate DATE pair (one pair per row via DB CHECK); display via core's
  offset-hours model (`DateUtils.shift_to_offset/2` etc.); the **"input
  frame"** (`@input_tz`) prevents form toggles from shifting the instant;
  "Use their timezone" cross-tz entry mode.
- **Participants table** (`phoenix_kit_calendar_event_participants`): loose
  `kind + target_uuid` refs (user/staff_person/crm_contact/crm_company/
  free_text) + `display_name` snapshot; full-replace-with-diff in one txn
  with **`FOR UPDATE` lock on the event** (`Participants.lock_event/1`) —
  the in-repo precedent for slot-capacity locking.
- **Migrations in core** (V141/V142), idempotent + additive, UUIDv7 PKs via
  `uuid_generate_v7()`, CHECK constraints mirrored in changesets.
- PubSub broadcast per mutation (minimal payload, no PII), Activity logging
  (title-privacy caveat), instant-open modals (`PkDialogTrigger` +
  `keep_in_dom` + `PkDialogDraft` reconnect draft), `to_lib_event/3`
  DB→lib-struct mapping, duck-typed dashboard widgets, `css_sources:
  [:phoenix_kit_calendar, :phoenix_live_calendar]` + `js_sources/0`.

### 1.3 Ecosystem integration points for bookings

| Need | What exists | Reference |
|---|---|---|
| Module scaffold | `use PhoenixKit.Module`; required: `module_key/enabled?/enable_system/disable_system/module_name`; `:phoenix_kit` in `extra_applications` or discovery 404s | `phoenix_kit_hello_world` (template), `routes.ex` fully documented |
| Routing (multi-page + public) | `route_module/0` with `admin_locale_routes/0` + `admin_routes/0` (both, distinct `:as`), `generate/1` for early public routes, `public_routes/1` only for catch-alls | `phoenix_kit_entities/routes.ex` (public `post /entities/:slug/submit` = closest analog to a public "create booking") |
| Providers (staff) | `Staff.list_people/1` (excludes trashed), `get_person_by_user_uuid/2`, placeholder-user flow, Teams/Departments/Skills/Employments. **`work_schedule` JSONB is PLANNED, not built** — weekly windows exactly shaped like provider availability; bookings may end up defining it | `phoenix_kit_staff/lib/phoenix_kit_staff/staff.ex`; projects consumes staff as a hard dep |
| Venues/rooms | `Locations` full CRUD + **`Spaces`** nested tree (floor/room/zone…) — a bookable room is directly modelable | `phoenix_kit_locations` (`spaces.ex`) |
| Paid bookings | Billing orders (draft→pending→confirmed→paid state machine, JSONB `line_items`, guest orders via `billing_snapshot.email`), provider behaviour (Stripe/PayPal/Razorpay/EveryPay hosted checkout), webhook controller with idempotency (+ host `CacheBodyReader` requirement). Flow to mirror: ecommerce `convert_cart_to_order/2` → checkout LV → update on `mark_order_paid` webhook | `phoenix_kit_billing`, `phoenix_kit_ecommerce/web/checkout_page.ex:378` |
| Confirmation emails / reminders | Core `PhoenixKit.Mailer` (`send_from_template/4` or ad-hoc Swoosh + `deliver_email/2`); Oban worker pattern for scheduled sends; emails module adds templates/logging/blocklist when enabled (`required_modules: ["emails"]` optional) | `phoenix_kit_newsletters/workers/delivery_worker.ex` (copy this shape) |
| In-app notifications | Core notifications fan out **automatically from Activity.log** when `target_uuid != actor_uuid` — never insert directly; module contributes `notification_types/0`; bell LV exists | `phoenix_kit/lib/phoenix_kit/notifications/`, hello_world `notification_types/0` |
| Settings | `settings_tabs/0` (`parent: :admin_settings`); `Settings.get_boolean_setting/2` + `update_*_with_module/3` (enable/disable pattern) | `phoenix_kit_emails` settings tab |
| Public URLs | `PhoenixKit.Utils.Routes.path/1` / `url/1` (emails need absolute), module `Paths` wrapper; locale-prefix policy via entities' `UrlResolver` pattern | hello_world/staff `paths.ex` |

**Conventions checklist** (each verified with a reference file): UUIDv7 PK
named `uuid`, `use PhoenixKit.SchemaPrefix` right after `use Ecto.Schema` +
conformance test, table names `phoenix_kit_bookings_*`, `timestamps(type:
:utc_datetime)`, soft-delete = status sentinel (never `deleted_at`),
module-owned `Activity` wrapper logging at LV layer, per-module `Errors`
module, hybrid gettext (own backend + core for generics), test/support
Endpoint+Router+LiveCase harness with `PhoenixKit.Migration.ensure_current/2`,
`pk_dep/3` in mix.exs, `mix precommit` gate, version synced in mix.exs
`@version` + `version/0`.

**Likely dependency shape**: core (required) · staff (providers — probably
hard, like projects) · phoenix_live_calendar (rules engine + UI — hard) ·
locations (soft) · billing (soft, paid bookings) · emails (soft; core mailer
suffices otherwise).

Note: the boss's newest modules `phoenix_kit_stats` (has code) /
`phoenix_kit_boards` (empty) exist on GitHub but are **not cloned locally**;
freshest local style references remain projects + calendar.

---

## 2. Feature landscape of existing booking products

Products surveyed: Calendly, Cal.com (open-source — schema read directly),
Microsoft Bookings, Google Appointment Schedules, SavvyCal, Acuity ·
SimplyBook.me, Setmore, Square Appointments, Fresha, Booksy, Vagaro ·
Easy!Appointments, Rallly, Hi.Events · OpenTable.

**Two paradigms**: meeting schedulers model availability as *the host's
calendar minus busy time* (external calendar sync is first-class); service
platforms model it as *staff rosters + bookable resources* with payments/CRM
attached. Acuity/Square/SimplyBook straddle both. A good module supports both
lenses.

### 2.1 Cal.com's domain model (the open-source reference skeleton)

`EventType (service) → Schedule → Availability (weekly rule | date override,
one table) → slot computation → Booking → Attendee / BookingSeat`, plus
**Host** (user↔event-type join for teams: `isFixed`, `priority`, `weight`)
and **BookingReference** (external-system ids: calendar event, video link).

Notable fields worth stealing:
- EventType: `periodType` (UNLIMITED | ROLLING | ROLLING_WINDOW | RANGE),
  `minimumBookingNotice`, `before/afterEventBuffer`, `slotInterval`,
  `offsetStart`, `bookingLimits`/`durationLimits` (Json caps per
  day/week/month/year), `requiresConfirmation` (+
  `requiresConfirmationWillBlockSlot`), `seatsPerTimeSlot` +
  `seatsShowAvailabilityCount`, `schedulingType` (ROUND_ROBIN | COLLECTIVE |
  MANAGED), `recurringEvent`, `lockTimeZoneToggleOnBookingPage`,
  `disableGuests/Cancelling/Rescheduling`, `metadata`.
- Booking: status enum `PENDING | ACCEPTED | REJECTED | CANCELLED |
  AWAITING_HOST`, `responses` (intake answers), `fromReschedule` (uid
  chain), `idempotencyKey`, `iCalUID`/`iCalSequence`, `noShowHost`,
  `cancelledBy`/`rescheduledBy`, `reassignReason`.
- **SelectedSlots** — TTL slot hold (`releaseAt`) during checkout = their
  double-booking race answer.
- Payment `paymentOption: ON_BOOKING | HOLD` (HOLD = card auth for no-show
  fee — no separate fee object).
- Webhook triggers incl. time-offset scheduled webhooks; Workflow = trigger
  + offset + action (email/SMS/WhatsApp) + template.
- OutOfOfficeEntry with **forwarding to a colleague**; HashedLink
  (single-use/expiring links); BookingInternalNote (staff-only notes).

### 2.2 Feature tiers (scoping cheat-sheet)

**The OSS floor** (Easy!Appointments): services + categories, providers with
working plans + exceptions + blocked periods, customer self-booking page,
email notifications + ICS, Google/CalDAV sync, admin CRUD, REST API.

**Table stakes for a credible module:**
- Event-type rules: duration, buffers before/after, min notice, booking
  window (rolling/range/unlimited), slot interval, per-period caps
- Named schedules (weekly hours, multiple intervals per day) + date
  overrides/blackouts + vacations
- TZ-correct slot engine (store UTC, render in booker tz; fixed-tz lock for
  in-person services)
- Public booking page: slot picker, guest booking (no account), custom
  intake questions, hidden/secret event types, prefill params
- Instant-confirm vs approval (pending) flows
- Seats/capacity (group events, show remaining)
- Reschedule/cancel via tokenized links, with policy windows; reasons
- Email confirmations + ICS + configurable reminders; staff notifications
- Admin: bookings dashboard (upcoming/past/pending/cancelled), per-staff
  calendar views, manual booking entry, roles
- Webhooks (created/rescheduled/cancelled + signature), embeds
- 2-way external calendar sync + conflict check (table stakes for meeting
  tools; less so for self-contained SaaS — likely a later phase here)

**Leader differentiators worth prioritizing:**
- Team scheduling: round-robin (weights, priority, fixed-hosts mix),
  collective (intersection), any-available-staff (the service-world RR)
- Slot **hold with TTL** during checkout
- No-show protection: card-on-file / auth-hold, late-cancel fees tied to
  the cancellation window (the salon-world killer feature)
- Waitlist with release strategies (Vagaro's 4 modes: manual /
  highest-value / first-in-line / notify-all-race)
- Resources (rooms/equipment) co-allocated with the appointment
- Routing forms; workflow engine (trigger+offset+action); managed/templated
  event types; recurring appointments/series; multi-service cart; add-ons;
  packages/memberships; OOO with forwarding; deposits
- Service-status pipeline (arrived/started/completed/no-show) + internal
  notes

**Niche** (note, don't build): SavvyCal overlay/ranked slots, meeting polls
(Rallly), instant meetings, dynamic group links (`/alice+bob`), marketplace,
POS/retail, HIPAA modes, restaurant pacing (though OpenTable's per-interval
"pacing cap" — capacity limiting decoupled from resources — generalizes
nicely, as does Square's "processing time" gap inside a service that stays
bookable for others).

---

## 3. Gap analysis — what this module must build

Everything below exists in no workspace lib today:

1. **Persistence of the booking domain** — core-owned migration adding
   tables for: service/event types (rules columns ≈ BookingConfig fields),
   provider schedules + availability rows (weekly rule | date override, à la
   Cal.com's single table — matches `PhoenixLiveCalendar.Availability`
   1:1), and bookings + attendees. The lib structs rehydrate from these
   rows; the engine is already written.
2. **Customer/booker capture** — guest name/email/phone + optional linked
   user; calendar-module participants are internal refs, not external
   customers (adapt the loose kind+target_uuid pattern + display_name
   snapshot).
3. **Lifecycle state machine** — pending → confirmed → cancelled /
   rescheduled / completed / no_show (+ rejected, + hold-with-expiry).
   `Event.status` atoms exist for display; transitions/enforcement don't.
   Billing's `status_changeset/2` transition validation is the in-house
   precedent.
4. **Double-book race protection** — DB-level: `FOR UPDATE` around the
   capacity check (precedent: `Participants.lock_event/1`) and/or a TTL
   slot-hold row (Cal.com SelectedSlots).
5. **Policies as stored config** — cancel/reschedule windows, notice,
   caps — BookingConfig is ephemeral today.
6. **Notifications** — confirmation/reminder/cancellation emails (Oban,
   newsletters worker shape), ICS attachment, in-app via Activity→
   Notifications fan-out, `notification_types/0`.
7. **Public booking surface** — unauthenticated LiveView/controller routes
   via `generate/1` (no catch-alls), locale-aware, distinct from the
   `bookings.*` admin sub-permission model.
8. **Payments (later phase)** — booking→order conversion mirroring
   ecommerce, deposits/no-show fees via billing providers.

---

## 4. Universality mandate (boss, 2026-07-25)

Two requirements from the boss, relayed by Max:

1. **Universal booking modes.** One module must cover: a hotel booking by
   the day/night, a massage parlor booking on the hour for an hour, and a
   gym with a free-form picker (any start, unlimited duration). "We need to
   be able to do anything."
2. **Heterogeneous coexistence.** A single install must run mixed modes at
   once — a hotel that also offers massage bookings. Therefore the booking
   mode is **per service/offer config, never a module-level setting**.

### 4.1 How this maps onto the existing engine (verified in source)

- `Constraints.validate_booking/5` already validates an **arbitrary**
  `[start, end)` range — slots exist only on the generation side
  (`bookable_slots`). Free-form (gym) is the engine's native validation
  mode; the calendar's `on_range_select` drag gesture is the picker.
- Fixed slots (massage) = `duration: 60, slot_interval: 60` — works today.
- **Blocker 1 — unbounded duration**: `effective_max_duration(nil)` falls
  back to `duration` (`booking_config.ex:104`), so "no limit" is
  inexpressible. Needs a small upstream tweak in `phoenix_live_calendar`
  (Max owns it): an explicit unbounded semantic (`:infinity` or
  nil-means-unbounded under a free-form flag).
- **Blocker 2 — day granularity**: `Availability` is time-of-day windows
  and all validators work in `DateTime`; there is no date-range path, no
  per-date inventory. Day/night mode is a genuinely new validation +
  counting path (see 4.4 — but NOT a second storage model).

### 4.2 What universal products do (research pass 2)

Surveyed: Checkfront + Planyo (self-described universal), Booqable + Twice
(rentals), Skedda + LibCal + LibreBooking (spaces), Cloudbeds + Mews (hotel
PMS), QloApps + HotelDruid (OSS hotel).

- **Checkfront**: per-product "How is your product booked?" — All day /
  Nightly / Timeslots / Flextime; API `unit: "D"|"N"|"H"`. Nightly differs
  from daily ONLY in end-date interpretation ("checkout = day after last
  booked date"). Pooled `stock` inventory, per-date overrides via an
  inventory calendar, date-scoped "availability events" carry min/max
  duration + lead time + guest counts (= seasonal rules).
- **Planyo**: mode is **derived, not chosen** — `min_rental_time < 1 day`
  ⇒ hour-based, `>= 1 day` ⇒ day-based; `is_overnight_stay` bool = the
  hotel switch. Duration mode three-way: always-same / freely-chosen /
  `predefined_durations` list. `start_quarters` (snap) + optional
  `start_times` list collapses free-form into fixed-slot with no second
  model. `quantity` pooled; `min_time_between_rentals` = turnover;
  `event_dates` = enumerated-sessions mode. Staff-override flag ("admins
  may choose any duration/start").
- **Mews** (the most principled): `Service.TimeUnitPeriod ∈ Hour|Day|Month`;
  reservations are ALWAYS UTC intervals; **"night" = Day unit +
  `StartOffset`/`EndOffset`** (check-in 14:00 = start-of-unit + 14h) with
  separate `OccupancyStartOffset/EndOffset` (when the unit is actually
  blocked — turnover built into the model). Book a
  `RequestedResourceCategoryId`; `AssignedResourceId` optional + lockable.
  Restrictions per date: `minLos`/`maxLos`, states Open/Closed/CTA/CTD/
  closed-to-stay.
- **Booqable**: `price_period ∈ hour|day|week|month|year`; per-product
  **`trackable` flag** = named serial-numbered units vs bulk quantity —
  the cleanest way to defer the pooled-vs-named-unit choice. `lead_time` /
  `lag_time` buffers. `/availability` computes over continuous ranges,
  *reports* at any requested interval.
- **Skedda/LibCal**: free-form reference — venue "time granularity" (snap),
  min/max/fixed-duration + allowed-start-times "booking conditions" scoped
  by space/weekday/time/user, padding between bookings, per-user quotas.
- **LibreBooking**: resources carry `min_duration`/`min_increment`/
  `max_duration`/`allow_multiday_reservations`/`min_notice_time`/
  `max_notice_time`/`autoassign`/`requires_approval`; bookings ALWAYS
  stored as datetime intervals; slot grids are **data** (`time_blocks`
  rows) used for validation/presentation only.
- **QloApps**: DATE `date_from/date_to` (exclusive end) + `check_in_time`/
  `check_out_time` as attribute strings; books a room *type*, allots a
  specific `id_room` (auto/manual). **HotelDruid** (integer day-IDs,
  yearly-sharded tables) is the cautionary tale — day-IDs buy nothing
  Postgres dates don't.

### 4.3 Taxonomy — six archetypes, one continuum

1. **Fixed slot** (start list/grid, fixed length) — massage
2. **Slot grid + choosable duration** (snapped start, allowed lengths)
3. **Free-form continuous** (any start, min–max or unbounded) — gym
4. **Open-ended** (start, no end; rentals) — probably out of v1
5. **Day/nightly** (dates only, exclusive end; min/max stay) — hotel
6. **Scheduled sessions** (admin-enumerated instances; classes)

1–3 are one parameter continuum: fixed slot = grid + single allowed
duration; grid = free-form + coarse snap (Planyo/Checkfront prove it with
shared vocab). 6 ≈ 1 with explicit dates. 5 is the coarser time base.
Cross-cutting params everywhere: capacity (pooled | named units |
exclusive), lead time, booking window, buffer/turnover, date-scoped rule
overrides, staff-override flag.

### 4.4 The unification the evidence favors (one model, not three)

Every universal product stores **one booking record with a continuous
interval** and drives behavior from per-service config; only hotel-only
OSS hard-codes date storage. Synthesis for this module:

- **One `bookings` shape**: UTC datetime pair, exclusive end. For
  day/night services the canonical `date_from`/`date_to` DATE pair is kept
  alongside (QloApps-style; matches the workspace's V141 timed-pair OR
  date-pair CHECK convention) so day-mode queries/min-stay/pricing never
  touch clock time or timezones. Check-in/check-out clock times are
  **service attributes, never range data** (Mews offsets).
- **Per-service config** (≈ BookingConfig columns + the day axis):
  `time_unit` (`:minutes | :day | :night`), snap/`slot_interval`,
  `min_duration`/`max_duration` (nullable = unbounded), optional
  `allowed_durations` list, optional `allowed_start_times` list,
  buffers, `min_notice`/`max_advance`, `seats`/quantity,
  `checkin_time`/`checkout_time`, min/max stay.
- **Capacity axis per service**: exclusive | pooled quantity | named
  bookable units with optional late assignment + lock (Booqable
  `trackable` / Mews category→resource). Pooled quantity alone provably
  runs small hotels (Checkfront/Planyo); named units are the obvious v2.
- **Date-scoped rules table** (one mechanism = seasons + blackouts + hotel
  restrictions): scoped by service/unit + date range + weekday mask,
  carrying min/max stay, closed/CTA/CTD, price overrides.
- **Conflict enforcement in Postgres** (none of the surveyed MySQL-era
  products have DB-level enforcement — we can beat them): exclusion
  constraint on range overlap for exclusive/named units; transactional
  overlap-count (`FOR UPDATE`) for pooled seats.
- Day-mode availability = units − overlapping bookings − closures per
  date; per-date pricing summed over the range (billing phase).

Coexistence (req 2) falls out of this design for free: services with
different `time_unit`/capacity configs live in the same tables, one admin,
one public page; conflict checks run against the service's own
provider/unit/capacity target, so the therapist's diary and the room
inventory never interact.

---

## 5. Open questions for the boss

- ~~Meeting-scheduler vs service-business paradigm~~ → **answered
  2026-07-25: universal — per-service modes, mixed installs.**
- Providers = staff people only, or any platform user? Should bookings
  define staff's planned-but-unbuilt `work_schedule`, or own its
  availability tables outright?
- v1 capacity axis: is pooled quantity enough (Checkfront/Planyo-style),
  or are named units (specific room assignment) needed from the start?
- Public page requirements: guest booking without account? Locale-prefixed
  URLs? Embeddable on host sites?
- Payments in v1 or later? Per-date (seasonal) pricing is a hotel
  table-stake — does v1 need prices at all, or bookings-only first?
- External calendar sync (Google/Outlook) — assume out of v1?
- Open-ended bookings (rentals, no end date) — in scope at all?
