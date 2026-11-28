defmodule PhoenixKitBookings.AvailabilityView do
  @moduledoc """
  Read-only availability per day — free / partly booked / booked — for a
  calendar that only shows, never books. Feeds
  `PhoenixKitBookings.Web.Components.AvailabilityCalendar` (the routed page
  of a service with `bookable_online: false`, and the widget's
  `"mode" => "availability"`).

  Statuses per date:

  - `:free` — nothing booked (every slot / seat open)
  - `:partial` — some booked, some still open
  - `:booked` — nothing left
  - `:closed` — the service's rules close the day (or no slot fits)
  - `:past` — before today in the site frame

  Day/night services count seats per date (`Engine.day_capacity/5`). Minute
  services read the slot grid (`Engine.bookable_slots/6`); a free-form
  service is read on a grid of its minimum length. Every booking counts,
  whatever its source, including imported busy entries.
  """

  alias PhoenixKitBookings.{Bookings, Engine, Services}
  alias PhoenixKitBookings.Engine.DayEngine
  alias PhoenixKitBookings.Schemas.Service

  @type status :: :free | :partial | :booked | :closed | :past

  @doc """
  `%{date => status}` for every date in `[from, until]` (inclusive).
  Options: `:today` (test injection), `:tz`, `:now`.
  """
  @spec day_statuses(Service.t(), Date.t(), Date.t(), keyword()) :: %{Date.t() => status()}
  def day_statuses(%Service{} = service, %Date{} = from, %Date{} = until, opts \\ []) do
    service = %{service | seats: Services.effective_seats(service)}
    rules = Services.list_rules(service.uuid)
    today = Keyword.get(opts, :today, Engine.today())
    statuses(service, rules, from, until, today, opts)
  end

  defp statuses(%Service{time_unit: unit} = service, rules, from, until, today, _opts)
       when unit in ["day", "night"] do
    bookings = Bookings.list_occupancy(service.uuid, {:dates, from, Date.add(until, 1)})
    remaining = Engine.day_capacity(service, rules, from, until, bookings)

    Map.new(Date.range(from, until), fn date ->
      status =
        cond do
          Date.compare(date, today) == :lt -> :past
          not DayEngine.open_date?(rules, date) -> :closed
          true -> seat_status(Map.get(remaining, date, 0), service.seats)
        end

      {date, status}
    end)
  end

  defp statuses(%Service{} = service, rules, from, until, today, opts) do
    tz = Keyword.get(opts, :tz, Engine.site_tz())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    grid = grid_service(service)
    pad = (service.buffer_before + service.buffer_after) * 60

    window_from = from |> Engine.from_frame(~T[00:00:00], tz) |> DateTime.add(-pad, :second)

    window_until =
      until |> Date.add(1) |> Engine.from_frame(~T[00:00:00], tz) |> DateTime.add(pad, :second)

    bookings = Bookings.list_occupancy(service.uuid, {window_from, window_until})

    Map.new(Date.range(from, until), fn date ->
      status =
        if Date.compare(date, today) == :lt do
          :past
        else
          grid
          |> Engine.bookable_slots(rules, date, bookings, tz, start_of_day(date, now, today, tz))
          |> slot_status(busy_on?(bookings, date, tz))
        end

      {date, status}
    end)
  end

  # Today is judged from now; a later date from its own midnight, so a slot
  # is never "unavailable" merely for lying ahead of the booking window the
  # site applies to bookings (this view shows occupancy, not bookability).
  defp start_of_day(date, now, today, tz) do
    if date == today, do: now, else: Engine.from_frame(date, ~T[00:00:00], tz)
  end

  # A free-form service has no grid of its own: read it on one of its
  # minimum length.
  defp grid_service(%Service{flexible_duration: true} = service) do
    length = service.min_duration || service.duration

    %{
      service
      | flexible_duration: false,
        duration: length,
        slot_interval: length,
        max_advance: nil,
        min_notice: 0
    }
  end

  defp grid_service(service), do: %{service | max_advance: nil, min_notice: 0}

  defp seat_status(0, _seats), do: :booked
  defp seat_status(remaining, seats) when remaining >= seats, do: :free
  defp seat_status(_remaining, _seats), do: :partial

  # Slots the rules close or that already passed are `:unavailable`, full ones
  # `:booked`. A pooled slot with seats left still reads `:available`, so
  # whether anything is booked that day comes from the bookings themselves.
  defp slot_status([], _busy?), do: :closed

  defp slot_status(slots, busy?) do
    statuses = Enum.map(slots, fn {_s, _e, status} -> status end)
    open = Enum.count(statuses, &(&1 == :available))
    full = Enum.count(statuses, &(&1 == :booked))

    cond do
      open == 0 and full == 0 -> :closed
      open == 0 -> :booked
      full == 0 and not busy? -> :free
      true -> :partial
    end
  end

  defp busy_on?(bookings, date, tz) do
    day_start = Engine.from_frame(date, ~T[00:00:00], tz)
    day_end = Engine.from_frame(Date.add(date, 1), ~T[00:00:00], tz)

    Enum.any?(bookings, fn
      %{starts_at: %DateTime{} = s, ends_at: %DateTime{} = e} ->
        DateTime.compare(s, day_end) == :lt and DateTime.compare(e, day_start) == :gt

      _ ->
        false
    end)
  end
end
