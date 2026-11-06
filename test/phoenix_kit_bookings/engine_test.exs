defmodule PhoenixKitBookings.EngineTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBookings.Engine
  alias PhoenixKitBookings.Engine.DayEngine
  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Booking, Service}
  alias PhoenixLiveCalendar.{Availability, BookingConfig}

  # Pure unit tests — no DB. The site offset resolves to "0" (Settings
  # unavailable rescues to the default), so frame == UTC here.

  defp minutes_service(attrs \\ []) do
    struct!(
      %Service{
        uuid: Ecto.UUID.generate(),
        name: "Massage",
        time_unit: "minutes",
        duration: 60,
        slot_interval: 60,
        buffer_before: 0,
        buffer_after: 0,
        min_notice: 0,
        seats: 1,
        flexible_duration: false,
        status: "active",
        signup_policy: "anyone",
        require_approval: false
      },
      attrs
    )
  end

  defp night_service(attrs \\ []) do
    struct!(
      %Service{
        uuid: Ecto.UUID.generate(),
        name: "Double room",
        time_unit: "night",
        duration: 60,
        seats: 3,
        buffer_before: 0,
        buffer_after: 0,
        min_notice: 0,
        status: "active",
        signup_policy: "anyone",
        require_approval: false
      },
      attrs
    )
  end

  defp rule(attrs) do
    struct!(%AvailabilityRule{available: true}, attrs)
  end

  defp booking_on(starts_on, ends_on, status \\ "confirmed") do
    %Booking{
      uuid: Ecto.UUID.generate(),
      starts_on: starts_on,
      ends_on: ends_on,
      status: status
    }
  end

  describe "site frame across daylight saving" do
    # Europe/Tallinn is UTC+2 in November and UTC+3 in July. Each conversion
    # must resolve the zone ON THE DATE CONVERTED — the previous code applied
    # today's offset to every date, so whichever season the suite runs in,
    # one of these two months came out an hour off.
    test "to_frame/2 shows the wall clock of the instant's own season" do
      assert Engine.to_frame(~U[2026-11-05 08:00:00Z], "Europe/Tallinn") ==
               ~U[2026-11-05 10:00:00Z]

      assert Engine.to_frame(~U[2026-07-05 07:00:00Z], "Europe/Tallinn") ==
               ~U[2026-07-05 10:00:00Z]
    end

    test "from_frame/3 stores the instant of the slot's own season" do
      assert Engine.from_frame(~D[2026-11-05], ~T[10:00:00], "Europe/Tallinn") ==
               ~U[2026-11-05 08:00:00Z]

      assert Engine.from_frame(~D[2026-07-05], ~T[10:00:00], "Europe/Tallinn") ==
               ~U[2026-07-05 07:00:00Z]
    end

    test "a legacy fixed offset never moves" do
      assert Engine.from_frame(~D[2026-11-05], ~T[10:00:00], "2") == ~U[2026-11-05 08:00:00Z]
      assert Engine.from_frame(~D[2026-07-05], ~T[10:00:00], "2") == ~U[2026-07-05 08:00:00Z]
      assert Engine.to_frame(~U[2026-07-05 08:00:00Z], "2") == ~U[2026-07-05 10:00:00Z]
    end

    test "the frame round-trips in both seasons" do
      for utc <- [~U[2026-01-15 21:30:00Z], ~U[2026-07-15 21:30:00Z]],
          tz <- ["Europe/Tallinn", "America/New_York", "5.5", "0"] do
        assert utc |> Engine.to_frame(tz) |> Engine.from_frame(tz) == utc, "#{tz} #{utc}"
      end
    end

    test "a skipped wall clock jumps forward, a repeated one takes the first occurrence" do
      # Tallinn springs forward 2026-03-29 03:00 → 04:00 and falls back
      # 2026-10-25 04:00 → 03:00.
      assert Engine.from_frame(~D[2026-03-29], ~T[03:30:00], "Europe/Tallinn") ==
               ~U[2026-03-29 01:00:00Z]

      assert Engine.from_frame(~D[2026-10-25], ~T[03:30:00], "Europe/Tallinn") ==
               ~U[2026-10-25 00:30:00Z]
    end

    test "microseconds survive the round trip" do
      utc = ~U[2026-07-15 08:00:00.123456Z]

      assert utc |> Engine.to_frame("Europe/Tallinn") |> Engine.from_frame("Europe/Tallinn") ==
               utc

      assert Engine.from_frame(~D[2026-07-15], ~T[10:00:00.5], "2") == ~U[2026-07-15 08:00:00.5Z]
    end

    # The dates below are fixed, so the clock has to be too.
    @year_start ~U[2026-01-01 00:00:00Z]

    test "slots inside a spring-forward gap are unavailable" do
      # Tallinn skips 03:00–03:59 on 2026-03-29.
      service = minutes_service(duration: 30, slot_interval: 30)

      slots =
        Engine.bookable_slots(service, [], ~D[2026-03-29], [], "Europe/Tallinn", @year_start)

      by_start = Map.new(slots, fn {start_t, _end_t, status} -> {start_t, status} end)

      assert by_start[~T[02:00:00]] == :available
      # 02:30–03:00 ends exactly at the jump: still thirty minutes, fine
      assert by_start[~T[02:30:00]] == :available
      assert by_start[~T[03:00:00]] == :unavailable
      assert by_start[~T[03:30:00]] == :unavailable
      assert by_start[~T[04:00:00]] == :available

      hour_slots =
        Engine.bookable_slots(
          minutes_service(duration: 60, slot_interval: 30),
          [],
          ~D[2026-03-29],
          [],
          "Europe/Tallinn",
          @year_start
        )

      hour_by_start = Map.new(hour_slots, fn {start_t, _end_t, status} -> {start_t, status} end)
      assert hour_by_start[~T[02:00:00]] == :available
      assert hour_by_start[~T[02:30:00]] == :unavailable
      assert hour_by_start[~T[04:00:00]] == :available

      # fall-back day (2026-10-25, 04:00 → 03:00): a slot starting in the
      # repeated hour and ending after it would store ninety minutes
      fall = Engine.bookable_slots(service, [], ~D[2026-10-25], [], "Europe/Tallinn", @year_start)
      fall_by_start = Map.new(fall, fn {start_t, _end_t, status} -> {start_t, status} end)
      assert fall_by_start[~T[02:30:00]] == :available
      assert fall_by_start[~T[03:00:00]] == :available
      assert fall_by_start[~T[03:30:00]] == :unavailable
      assert fall_by_start[~T[04:00:00]] == :available

      # The same grid on an ordinary day, or in a zone that never moves, is untouched.
      assert Engine.bookable_slots(service, [], ~D[2026-03-28], [], "Europe/Tallinn", @year_start)
             |> Enum.all?(fn {_s, _e, status} -> status == :available end)

      assert Engine.bookable_slots(service, [], ~D[2026-03-29], [], "2", @year_start)
             |> Enum.all?(fn {_s, _e, status} -> status == :available end)
    end

    test "frame_span_intact?/5 refuses a span the zone would not store as picked" do
      # The fixed-slot grid marks these unavailable, but a free-form service
      # has no grid and both pickers take their times from the client — so the
      # predicate is what the public flow calls before building a range.
      refute Engine.frame_span_intact?(
               ~D[2026-03-29],
               ~T[02:30:00],
               ~D[2026-03-29],
               ~T[03:30:00],
               "Europe/Tallinn"
             )

      refute Engine.frame_span_intact?(
               ~D[2026-10-25],
               ~T[03:30:00],
               ~D[2026-10-25],
               ~T[04:00:00],
               "Europe/Tallinn"
             )

      # Ends exactly at the jump, an ordinary day, and a zone that never
      # moves are all intact.
      assert Engine.frame_span_intact?(
               ~D[2026-03-29],
               ~T[02:30:00],
               ~D[2026-03-29],
               ~T[03:00:00],
               "Europe/Tallinn"
             )

      assert Engine.frame_span_intact?(
               ~D[2026-03-28],
               ~T[02:30:00],
               ~D[2026-03-28],
               ~T[03:30:00],
               "Europe/Tallinn"
             )

      assert Engine.frame_span_intact?(
               ~D[2026-03-29],
               ~T[02:30:00],
               ~D[2026-03-29],
               ~T[03:30:00],
               "2"
             )

      # A span crossing midnight is measured against its own end date.
      assert Engine.frame_span_intact?(
               ~D[2026-03-28],
               ~T[23:00:00],
               ~D[2026-03-29],
               ~T[01:00:00],
               "Europe/Tallinn"
             )
    end

    test "an unresolvable zone value degrades to UTC" do
      assert Engine.from_frame(~D[2026-07-05], ~T[10:00:00], "nonsense") ==
               ~U[2026-07-05 10:00:00Z]

      assert Engine.to_frame(~U[2026-07-05 10:00:00Z], "nonsense") == ~U[2026-07-05 10:00:00Z]
    end
  end

  describe "booking_config/1" do
    test "fixed-slot service maps duration and interval, no free-form bounds" do
      config = Engine.booking_config(minutes_service())

      assert %BookingConfig{duration: 60, slot_interval: 60, seats: 1} = config
      assert BookingConfig.effective_min_duration(config) == 60
      assert BookingConfig.effective_max_duration(config) == 60
    end

    test "flexible service with nil max_duration maps to the unbounded sentinel" do
      config =
        Engine.booking_config(
          minutes_service(flexible_duration: true, min_duration: 30, max_duration: nil)
        )

      assert BookingConfig.effective_min_duration(config) == 30
      # An 8-hour gym session must not trip :too_long.
      assert BookingConfig.effective_max_duration(config) > 8 * 60
    end

    test "flexible service with explicit max keeps it" do
      config =
        Engine.booking_config(
          minutes_service(flexible_duration: true, min_duration: 30, max_duration: 120)
        )

      assert BookingConfig.effective_max_duration(config) == 120
    end
  end

  describe "lib_availability/1" do
    test "no rules synthesizes an always-open week" do
      assert [%Availability{days_of_week: [1, 2, 3, 4, 5, 6, 7], available: true}] =
               Engine.lib_availability([])
    end

    test "maps rule rows onto lib structs" do
      rules = [
        rule(days_of_week: [1, 2], start_time: ~T[09:00:00], end_time: ~T[17:00:00]),
        rule(date: ~D[2030-01-01], available: false)
      ]

      assert [
               %Availability{days_of_week: [1, 2], start_time: ~T[09:00:00]},
               %Availability{date: ~D[2030-01-01], available: false}
             ] = Engine.lib_availability(rules)
    end
  end

  describe "validate_request/5 — minute services" do
    test "free-form multi-hour booking passes with no ceiling" do
      service = minutes_service(flexible_duration: true, min_duration: 30, max_duration: nil)
      starts_at = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)
      ends_at = DateTime.add(starts_at, 5 * 3600, :second)

      assert :ok = Engine.validate_request(service, [], {starts_at, ends_at}, [])
    end

    test "rejects a range shape that doesn't match the unit" do
      service = minutes_service()

      assert {:error, :invalid_range, _} =
               Engine.validate_request(service, [], {:dates, ~D[2030-01-01], ~D[2030-01-02]}, [])
    end
  end

  describe "DayEngine.validate/6" do
    @today ~D[2030-06-10]

    test "accepts a valid stay" do
      assert :ok =
               DayEngine.validate(night_service(), [], ~D[2030-06-15], ~D[2030-06-17], [],
                 today: @today
               )
    end

    test "rejects inverted and same-day ranges" do
      assert {:error, :invalid_range, _} =
               DayEngine.validate(night_service(), [], ~D[2030-06-15], ~D[2030-06-15], [],
                 today: @today
               )
    end

    test "rejects past arrivals" do
      assert {:error, :in_past, _} =
               DayEngine.validate(night_service(), [], ~D[2030-06-09], ~D[2030-06-11], [],
                 today: @today
               )
    end

    test "enforces min_stay and max_stay" do
      service = night_service(min_stay: 2, max_stay: 4)

      assert {:error, :too_short, _} =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-16], [], today: @today)

      assert {:error, :too_long, _} =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-20], [], today: @today)

      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-18], [], today: @today)
    end

    test "enforces max_advance and day-granular min_notice" do
      service = night_service(max_advance: 10, min_notice: 2 * 1440)

      assert {:error, :too_far_ahead, _} =
               DayEngine.validate(service, [], ~D[2030-06-25], ~D[2030-06-26], [], today: @today)

      assert {:error, :insufficient_notice, _} =
               DayEngine.validate(service, [], ~D[2030-06-11], ~D[2030-06-12], [], today: @today)
    end

    test "a blackout date override blocks stays covering it" do
      rules = [rule(date: ~D[2030-06-16], available: false)]

      assert {:error, :outside_availability, _} =
               DayEngine.validate(night_service(), rules, ~D[2030-06-15], ~D[2030-06-17], [],
                 today: @today
               )

      # A stay ending on the blackout date (exclusive end) is fine.
      assert :ok =
               DayEngine.validate(night_service(), rules, ~D[2030-06-15], ~D[2030-06-16], [],
                 today: @today
               )
    end

    test "pooled capacity: the seat taken by overlapping stays" do
      service = night_service(seats: 2)

      active = [
        booking_on(~D[2030-06-15], ~D[2030-06-18]),
        booking_on(~D[2030-06-16], ~D[2030-06-17])
      ]

      # 2030-06-16 has both stays -> full.
      assert {:error, :at_capacity, _} =
               DayEngine.validate(service, [], ~D[2030-06-16], ~D[2030-06-17], active,
                 today: @today
               )

      # 2030-06-17 only overlaps the first stay -> one seat free.
      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-17], ~D[2030-06-18], active,
                 today: @today
               )
    end

    test "cancelled bookings free their seats" do
      service = night_service(seats: 1)
      active = [booking_on(~D[2030-06-15], ~D[2030-06-17], "cancelled")]

      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-17], active,
                 today: @today
               )
    end
  end

  describe "DayEngine.open_date?/2 weekly semantics" do
    test "with only weekly OPEN rules, unlisted weekdays are closed" do
      rules = [rule(days_of_week: [1, 2, 3, 4, 5])]

      assert DayEngine.open_date?(rules, ~D[2030-06-10])
      refute DayEngine.open_date?(rules, ~D[2030-06-15])
    end

    test "with only block-outs, unlisted days stay open" do
      rules = [rule(days_of_week: [7], available: false)]

      assert DayEngine.open_date?(rules, ~D[2030-06-10])
      refute DayEngine.open_date?(rules, ~D[2030-06-16])
    end

    test "a date override wins over weekly rules" do
      rules = [
        rule(days_of_week: [1, 2, 3, 4, 5]),
        rule(date: ~D[2030-06-15], available: true)
      ]

      # Saturday, normally closed — opened by the override.
      assert DayEngine.open_date?(rules, ~D[2030-06-15])
    end
  end

  describe "DayEngine.capacity_by_date/5" do
    test "maps remaining seats per date with closures at zero" do
      service = night_service(seats: 2)
      rules = [rule(date: ~D[2030-06-12], available: false)]
      active = [booking_on(~D[2030-06-10], ~D[2030-06-12])]

      capacity =
        DayEngine.capacity_by_date(service, rules, ~D[2030-06-10], ~D[2030-06-13], active)

      assert capacity[~D[2030-06-10]] == 1
      assert capacity[~D[2030-06-11]] == 1
      assert capacity[~D[2030-06-12]] == 0
      assert capacity[~D[2030-06-13]] == 2
    end
  end

  describe "bookings_to_events/2" do
    test "seat-1 services produce blocking events, pooled produce countable" do
      timed = %Booking{
        uuid: Ecto.UUID.generate(),
        status: "confirmed",
        starts_at: ~U[2030-06-10 10:00:00Z],
        ends_at: ~U[2030-06-10 11:00:00Z]
      }

      assert [%PhoenixLiveCalendar.Event{overlap: false}] =
               Engine.bookings_to_events([timed], minutes_service(seats: 1))

      assert [%PhoenixLiveCalendar.Event{overlap: true}] =
               Engine.bookings_to_events([timed], minutes_service(seats: 5))
    end

    test "cancelled and dated bookings are dropped" do
      cancelled = %Booking{
        uuid: Ecto.UUID.generate(),
        status: "cancelled",
        starts_at: ~U[2030-06-10 10:00:00Z],
        ends_at: ~U[2030-06-10 11:00:00Z]
      }

      dated = booking_on(~D[2030-06-10], ~D[2030-06-12])

      assert [] = Engine.bookings_to_events([cancelled, dated], minutes_service())
    end
  end

  describe "closed rules on minute services" do
    # 2030-06-12 is a Wednesday.
    defp open_slots(service, rules, date) do
      service
      |> Engine.bookable_slots(rules, date, [], "0", ~U[2030-01-01 00:00:00Z])
      |> Enum.filter(fn {_start, _end, status} -> status == :available end)
    end

    defp validate_at(service, rules, %Date{} = date) do
      starts_at = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

      Engine.validate_request(
        service,
        rules,
        {starts_at, DateTime.add(starts_at, 3600, :second)},
        [],
        now: ~U[2030-01-01 00:00:00Z]
      )
    end

    test "one blackout date leaves an always-open service open on every other day" do
      service = minutes_service()
      rules = [rule(date: ~D[2030-06-12], available: false)]

      assert open_slots(service, rules, ~D[2030-06-11]) != []
      assert open_slots(service, rules, ~D[2030-06-12]) == []
      assert :ok = validate_at(service, rules, ~D[2030-06-11])
      assert {:error, :outside_availability, _} = validate_at(service, rules, ~D[2030-06-12])
    end

    test "a closed weekday alone leaves the other days open" do
      service = minutes_service()
      rules = [rule(days_of_week: [3], available: false)]

      assert open_slots(service, rules, ~D[2030-06-11]) != []
      assert open_slots(service, rules, ~D[2030-06-12]) == []
    end

    test "a closed weekday beats the open rule that covers it" do
      service = minutes_service()

      rules = [
        rule(days_of_week: [1, 2, 3, 4, 5], start_time: ~T[09:00:00], end_time: ~T[17:00:00]),
        rule(days_of_week: [3], available: false)
      ]

      assert open_slots(service, rules, ~D[2030-06-11]) != []
      assert open_slots(service, rules, ~D[2030-06-12]) == []
      assert {:error, :outside_availability, _} = validate_at(service, rules, ~D[2030-06-12])
    end

    test "an open date with no weekly rules stays the only open date" do
      service = minutes_service()

      rules = [
        rule(date: ~D[2030-06-12], start_time: ~T[10:00:00], end_time: ~T[12:00:00])
      ]

      assert open_slots(service, rules, ~D[2030-06-12]) != []
      assert open_slots(service, rules, ~D[2030-06-13]) == []
    end
  end

  describe "DayEngine rules" do
    test "an open date with no weekly rules is the only open date, as on minute services" do
      rules = [rule(date: ~D[2030-06-12], available: true)]

      assert DayEngine.open_date?(rules, ~D[2030-06-12])
      refute DayEngine.open_date?(rules, ~D[2030-06-13])
    end
  end

  describe "DayEngine stay ceiling" do
    test "a stay with no maximum still stops at a year, like a free-form booking" do
      service = night_service(max_stay: nil)

      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2031-06-15], [], today: @today)

      assert {:error, :too_long, _} =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[9999-12-31], [], today: @today)
    end

    test "a configured maximum above the ceiling is honoured" do
      service = night_service(max_stay: 500)

      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2031-10-01], [], today: @today)
    end
  end

  describe "bookable_slots/6 — what can be booked from now" do
    defp status_at(slots, time) do
      {_start, _end, status} = Enum.find(slots, fn {start, _end, _status} -> start == time end)
      status
    end

    test "a slot already past today is not offered" do
      # 15:00 UTC is 10:00 in New York in January.
      slots =
        Engine.bookable_slots(
          minutes_service(),
          [],
          ~D[2030-01-15],
          [],
          "America/New_York",
          ~U[2030-01-15 15:00:00Z]
        )

      assert status_at(slots, ~T[09:00:00]) == :unavailable
      assert status_at(slots, ~T[11:00:00]) == :available
    end

    test "notice counts from the site's clock west of UTC" do
      slots =
        Engine.bookable_slots(
          minutes_service(min_notice: 60),
          [],
          ~D[2030-01-15],
          [],
          "America/New_York",
          ~U[2030-01-15 15:00:00Z]
        )

      # 10:00 there: 11:00 is an hour away. Read against the UTC clock it looks
      # five hours gone, and the morning goes unsold.
      assert status_at(slots, ~T[10:00:00]) == :unavailable
      assert status_at(slots, ~T[11:00:00]) == :available
    end

    test "notice never reads the lib's UTC clock against the site's wall clock" do
      # Today's date, because the lib reads the real clock: on any other day it
      # is too far away to matter. A fixed offset, so no daylight-saving day can
      # make the slot unavailable for another reason.
      tz = "-5"
      now = DateTime.utc_now()
      two_hours_on = now |> Engine.to_frame(tz) |> DateTime.add(2 * 3600, :second)
      slot_start = %{DateTime.to_time(two_hours_on) | minute: 0, second: 0, microsecond: {0, 0}}

      slots =
        Engine.bookable_slots(
          minutes_service(min_notice: 60),
          [],
          DateTime.to_date(two_hours_on),
          [],
          tz,
          now
        )

      assert status_at(slots, slot_start) == :available
    end

    test "notice counts from the site's clock east of UTC" do
      # 08:00 UTC is 10:00 in Tallinn in January.
      slots =
        Engine.bookable_slots(
          minutes_service(min_notice: 60),
          [],
          ~D[2030-01-15],
          [],
          "Europe/Tallinn",
          ~U[2030-01-15 08:00:00Z]
        )

      assert status_at(slots, ~T[10:00:00]) == :unavailable
      assert status_at(slots, ~T[11:00:00]) == :available
    end

    test "max_advance counts from the site's date" do
      slots =
        Engine.bookable_slots(
          minutes_service(max_advance: 1),
          [],
          ~D[2030-01-16],
          [],
          "Pacific/Auckland",
          ~U[2030-01-15 20:00:00Z]
        )

      # Already the 16th in Auckland, so the 16th is today, well inside the limit.
      assert status_at(slots, ~T[23:00:00]) == :available
    end
  end

  describe "AvailabilityRule times" do
    test "a closed rule on a minute service needs no times: it closes the day" do
      changeset =
        AvailabilityRule.changeset(
          %AvailabilityRule{},
          %{"date" => "2030-06-12", "available" => false},
          "minutes"
        )

      assert changeset.valid?
    end

    test "an open rule on a minute service still needs both times" do
      changeset =
        AvailabilityRule.changeset(
          %AvailabilityRule{},
          %{"days_of_week" => [1], "available" => true},
          "minutes"
        )

      refute changeset.valid?
    end
  end
end
