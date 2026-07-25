defmodule PhoenixKitBookings.Engine do
  @moduledoc """
  Adapter between the Bookings domain and `phoenix_live_calendar`'s booking
  rules engine (Layer 3: `BookingConfig` / `Availability` / `Constraints` /
  `TimeSlots`), plus the day/night path (`DayEngine`) the lib doesn't cover.

  ## Time frame

  All minute-unit math runs in the **site frame** — wall-clock time in the
  site's configured offset (core's offset-hours model, `"time_zone"`
  setting). v1 services are physical (hotel / massage parlor / gym), so
  slots are shown and validated in venue-local time regardless of the
  viewer (the Cal.com `lockTimeZoneToggleOnBookingPage` behavior). Storage
  is always true UTC: `frame_to_utc/1` on the way in, `utc_to_frame/1` on
  the way out. Frame datetimes are UTC-tagged shifted values (the same
  trick as core's `DateUtils.shift_to_offset/2` display path).

  Day/night services never touch clock time — dates are frame-free by the
  workspace's all-day convention.

  ## Unbounded duration

  `BookingConfig.effective_max_duration/1` treats `nil` as "same as
  `duration`", so a free-form service with no ceiling (`max_duration:
  nil`) maps to a large sentinel instead; real fit is still enforced by
  the availability-window check. (Candidate upstream tweak: an explicit
  unbounded semantic in the lib.)
  """

  alias PhoenixKitBookings.Engine.DayEngine
  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Booking, Service}
  alias PhoenixLiveCalendar.{Availability, BookingConfig, Event}
  alias PhoenixLiveCalendar.Utils.{Constraints, TimeSlots}

  # 366 days in minutes — "no ceiling" sentinel for free-form services.
  @unbounded_minutes 527_040

  # ── Config mapping ───────────────────────────────────────────────────

  @doc "Maps a Service row onto the lib's `%BookingConfig{}` (minute units)."
  def booking_config(%Service{} = service) do
    {min_dur, max_dur} =
      if service.flexible_duration do
        {service.min_duration || service.duration, service.max_duration || @unbounded_minutes}
      else
        {nil, nil}
      end

    %BookingConfig{
      duration: service.duration,
      min_duration: min_dur,
      max_duration: max_dur,
      slot_interval: service.slot_interval,
      buffer_before: service.buffer_before,
      buffer_after: service.buffer_after,
      min_notice: service.min_notice,
      max_advance: service.max_advance,
      seats: service.seats,
      availability: [],
      timezone: nil
    }
  end

  @doc """
  Maps availability rules onto lib `%Availability{}` structs. A service
  with no rules is always open — a synthetic full-day window keeps slot
  generation and validation consistent.
  """
  def lib_availability([]), do: [full_day_window()]

  def lib_availability(rules) when is_list(rules) do
    Enum.map(rules, fn %AvailabilityRule{} = rule ->
      %Availability{
        days_of_week: rule.days_of_week,
        date: rule.date,
        start_time: rule.start_time || ~T[00:00:00],
        end_time: rule.end_time || ~T[23:59:59],
        available: rule.available,
        resource_id: nil
      }
    end)
  end

  defp full_day_window do
    %Availability{
      days_of_week: [1, 2, 3, 4, 5, 6, 7],
      start_time: ~T[00:00:00],
      end_time: ~T[23:59:59],
      available: true
    }
  end

  # ── Validation ───────────────────────────────────────────────────────

  @doc """
  Validates a booking request against the service's rules and the current
  active bookings. Advisory — `PhoenixKitBookings.Bookings.create_booking/5`
  re-runs it inside a locked transaction.

  `range` is `{starts_at_utc, ends_at_utc}` (DateTime, minute services) or
  `{:dates, starts_on, ends_on}` (day/night services).

  Returns `:ok | {:error, reason_atom, message}`.
  """
  def validate_request(service, rules, range, active_bookings, opts \\ [])

  def validate_request(
        %Service{time_unit: "minutes"} = service,
        rules,
        {%DateTime{} = starts_at, %DateTime{} = ends_at},
        active_bookings,
        opts
      ) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Constraints.validate_booking(
      utc_to_frame(starts_at),
      utc_to_frame(ends_at),
      booking_config(service),
      bookings_to_events(active_bookings, service),
      now: utc_to_frame(now),
      availabilities: lib_availability(rules)
    )
  end

  def validate_request(
        %Service{time_unit: unit} = service,
        rules,
        {:dates, %Date{} = starts_on, %Date{} = ends_on},
        active_bookings,
        opts
      )
      when unit in ["day", "night"] do
    DayEngine.validate(service, rules, starts_on, ends_on, active_bookings,
      today: Keyword.get(opts, :today, today())
    )
  end

  def validate_request(_service, _rules, _range, _bookings, _opts),
    do: {:error, :invalid_range, "Request shape does not match the service's time unit"}

  # ── Slot / day generation for pickers ────────────────────────────────

  @doc """
  Bookable slots of a minute service on a frame-local date:
  `[{start_time, end_time, :available | :booked | :unavailable}]`.
  """
  def bookable_slots(%Service{time_unit: "minutes"} = service, rules, %Date{} = date, bookings) do
    TimeSlots.bookable_slots(
      date,
      %{booking_config(service) | availability: nil},
      lib_availability(rules),
      bookings_to_events(bookings, service)
    )
  end

  @doc """
  Per-date remaining capacity of a day/night service over a date range:
  `%{date => remaining_seats}`. Closed dates map to `0`.
  """
  def day_capacity(%Service{} = service, rules, %Date{} = from, %Date{} = until, bookings) do
    DayEngine.capacity_by_date(service, rules, from, until, bookings)
  end

  # ── Event mapping ────────────────────────────────────────────────────

  @doc """
  Maps active bookings onto lib `%Event{}`s in the site frame.

  `overlap: seats > 1` is deliberate: with one seat the event must BLOCK
  (`Constraints.validate_no_overlap` rejects only `overlap: false`
  events); with pooled seats events must pass the overlap check and be
  COUNTED by `validate_capacity`/`slot_status` instead.

  Each event is pre-expanded by the service buffers
  (`[start - buffer_before, end + buffer_after)`) because the lib buffers
  only the REQUEST side: with both sides expanded, two consecutive
  bookings need a gap of `buffer_after + buffer_before` — the existing
  booking's cleanup plus the new booking's prep — which is the intended
  semantics for a shared per-service buffer config.
  """
  def bookings_to_events(bookings, %Service{} = service) do
    pooled = service.seats > 1
    before_s = service.buffer_before * 60
    after_s = service.buffer_after * 60

    bookings
    |> Enum.filter(&(Booking.active?(&1) and not is_nil(&1.starts_at)))
    |> Enum.map(fn booking ->
      %Event{
        id: booking.uuid,
        title: "",
        start: booking.starts_at |> utc_to_frame() |> DateTime.add(-before_s, :second),
        end: booking.ends_at |> utc_to_frame() |> DateTime.add(after_s, :second),
        overlap: pooled,
        status: :confirmed
      }
    end)
  end

  # ── Site time frame ──────────────────────────────────────────────────

  @doc "Site offset in seconds (core offset-hours `\"time_zone\"` setting)."
  def site_offset_seconds do
    PhoenixKit.Utils.Date.offset_to_seconds(site_offset())
  rescue
    _ -> 0
  end

  defp site_offset do
    PhoenixKit.Settings.get_setting("time_zone", "0")
  rescue
    _ -> "0"
  catch
    :exit, _ -> "0"
  end

  @doc "Shifts a true-UTC datetime into the site frame (UTC-tagged wall clock)."
  def utc_to_frame(%DateTime{} = dt), do: DateTime.add(dt, site_offset_seconds(), :second)

  @doc "Shifts a site-frame wall clock back to true UTC."
  def frame_to_utc(%DateTime{} = dt), do: DateTime.add(dt, -site_offset_seconds(), :second)

  @doc "Builds a true-UTC datetime from a frame-local date + time."
  def frame_to_utc(%Date{} = date, %Time{} = time) do
    date
    |> DateTime.new!(time, "Etc/UTC")
    |> frame_to_utc()
  end

  @doc "Today's date in the site frame."
  def today, do: DateTime.utc_now() |> utc_to_frame() |> DateTime.to_date()
end
