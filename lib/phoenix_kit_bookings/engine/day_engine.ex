defmodule PhoenixKitBookings.Engine.DayEngine do
  @moduledoc """
  Validation + per-date capacity for day/night services — the date-granular
  path `phoenix_live_calendar`'s minute-based engine doesn't cover.

  Semantics (hotel conventions, universal-products research):

  - A stay is `[starts_on, ends_on)` — exclusive end. `ends_on` is the
    checkout date; nights = `Date.diff(ends_on, starts_on)`. For
    `time_unit: "day"` the same math reads as whole days.
  - Check-in/check-out clock times are service display attributes and take
    no part in availability math.
  - A date is **open** when: a date-override rule on it says
    `available: true`, or (no override) a weekly rule covers its weekday
    with `available: true` and no closed weekly rule does, or the service
    has no open rule at all and nothing closes the date. Every
    OCCUPIED date `[starts_on, ends_on)` must be open (blackout = closed
    date; closed-to-arrival/-departure refinements are post-v1).
  - A stay with no `max_stay` still ends within `@unbounded_days`, the
    ceiling free-form minute services have (`Engine`): without one, a single
    public request could take a room for the rest of the calendar, and
    every check below walks each date of the stay.
  - Capacity is pooled per date: active bookings covering a date must stay
    below `seats` (7 rooms of a type — Checkfront/Planyo-style; named unit
    assignment is post-v1).
  """

  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Booking, Service}

  @unbounded_days 366

  @doc """
  Validates a `[starts_on, ends_on)` stay request.

  Returns `:ok | {:error, reason, message}` with the same reason-atom
  vocabulary as `PhoenixLiveCalendar.Utils.Constraints` where shapes match
  (`:invalid_range`, `:in_past`, `:insufficient_notice`, `:too_far_ahead`,
  `:too_short`, `:too_long`, `:outside_availability`, `:at_capacity`).
  """
  def validate(%Service{} = service, rules, starts_on, ends_on, active_bookings, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())

    with :ok <- validate_order(starts_on, ends_on),
         :ok <- validate_not_in_past(starts_on, today),
         :ok <- validate_notice(starts_on, today, service),
         :ok <- validate_advance(starts_on, today, service),
         :ok <- validate_stay(starts_on, ends_on, service),
         :ok <- validate_open_dates(starts_on, ends_on, rules) do
      validate_capacity(starts_on, ends_on, service, active_bookings)
    end
  end

  @doc """
  Remaining seats per date over `[from, until]` (inclusive — a picker
  month): `%{date => remaining}`, `0` for closed or full dates.
  """
  def capacity_by_date(%Service{} = service, rules, from, until, bookings) do
    active = Enum.filter(bookings, &(Booking.active?(&1) and &1.starts_on))

    Map.new(Date.range(from, until), fn date ->
      remaining =
        if open_date?(rules, date) do
          max(service.seats - occupied_count(active, date), 0)
        else
          0
        end

      {date, remaining}
    end)
  end

  @doc "True when the date is open per the service's rules (see moduledoc)."
  def open_date?([], _date), do: true

  def open_date?(rules, %Date{} = date) do
    case Enum.filter(rules, &(&1.date == date)) do
      [] -> weekly_open?(rules, date)
      overrides -> Enum.any?(overrides, & &1.available)
    end
  end

  defp weekly_open?(rules, date) do
    weekday = Date.day_of_week(date)

    weekly =
      Enum.filter(rules, fn %AvailabilityRule{} = rule ->
        is_nil(rule.date) and is_list(rule.days_of_week) and weekday in rule.days_of_week
      end)

    case weekly do
      [] ->
        # No weekly rule mentions this weekday. If the service has OPEN rules
        # at all, what they do not cover is closed; with only block-outs
        # configured, unlisted days stay open.
        not Enum.any?(rules, & &1.available)

      matched ->
        Enum.all?(matched, & &1.available)
    end
  end

  defp occupied_count(active_bookings, date) do
    Enum.count(active_bookings, fn b ->
      Date.compare(b.starts_on, date) != :gt and Date.compare(date, b.ends_on) == :lt
    end)
  end

  # ── Validators ───────────────────────────────────────────────────────

  defp validate_order(starts_on, ends_on) do
    if Date.compare(starts_on, ends_on) == :lt do
      :ok
    else
      {:error, :invalid_range, "Check-out must be after check-in"}
    end
  end

  defp validate_not_in_past(starts_on, today) do
    if Date.compare(starts_on, today) == :lt do
      {:error, :in_past, "Cannot book in the past"}
    else
      :ok
    end
  end

  defp validate_notice(_starts_on, _today, %Service{min_notice: 0}), do: :ok

  defp validate_notice(starts_on, today, %Service{min_notice: minutes}) do
    days_notice = div(minutes + 1439, 1440)

    if Date.compare(starts_on, Date.add(today, days_notice)) == :lt do
      {:error, :insufficient_notice,
       "Booking requires at least #{days_notice} day(s) advance notice"}
    else
      :ok
    end
  end

  defp validate_advance(_starts_on, _today, %Service{max_advance: nil}), do: :ok

  defp validate_advance(starts_on, today, %Service{max_advance: days}) do
    if Date.compare(starts_on, Date.add(today, days)) == :gt do
      {:error, :too_far_ahead, "Cannot book more than #{days} days in advance"}
    else
      :ok
    end
  end

  defp validate_stay(starts_on, ends_on, %Service{} = service) do
    units = Date.diff(ends_on, starts_on)
    min_stay = service.min_stay || 1
    max_stay = service.max_stay || @unbounded_days
    unit_word = if service.time_unit == "night", do: "night(s)", else: "day(s)"

    cond do
      units < min_stay ->
        {:error, :too_short, "Minimum stay is #{min_stay} #{unit_word}"}

      units > max_stay ->
        {:error, :too_long, "Maximum stay is #{max_stay} #{unit_word}"}

      true ->
        :ok
    end
  end

  defp validate_open_dates(starts_on, ends_on, rules) do
    occupied = Date.range(starts_on, Date.add(ends_on, -1))

    if Enum.all?(occupied, &open_date?(rules, &1)) do
      :ok
    else
      {:error, :outside_availability, "The selected dates include closed days"}
    end
  end

  defp validate_capacity(starts_on, ends_on, %Service{seats: seats}, active_bookings) do
    active = Enum.filter(active_bookings, &(Booking.active?(&1) and &1.starts_on))
    occupied = Date.range(starts_on, Date.add(ends_on, -1))

    full_date = Enum.find(occupied, fn date -> occupied_count(active, date) >= seats end)

    if full_date do
      {:error, :at_capacity, "No availability on #{Date.to_iso8601(full_date)}"}
    else
      :ok
    end
  end
end
