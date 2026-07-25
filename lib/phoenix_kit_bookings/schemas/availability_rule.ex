defmodule PhoenixKitBookings.Schemas.AvailabilityRule do
  @moduledoc """
  One availability rule of a service. Maps 1:1 onto
  `PhoenixLiveCalendar.Availability`:

  - **Weekly rule** — `days_of_week` set (ISO 1=Mon..7=Sun), `date` nil.
  - **Date override** — `date` set; overrides every weekly rule on that
    date (the lib's precedence rule).
  - `available: false` turns either shape into a block-out (a closed
    weekday or a blackout date).

  For minute-unit services `start_time`/`end_time` bound the bookable
  window (both required). For day/night services the rule is date-granular
  and times stay nil — a weekly rule marks open days (arrival days), a
  date override closes or opens a specific date.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_availability_rules" do
    field(:service_uuid, UUIDv7)
    field(:days_of_week, {:array, :integer})
    field(:date, :date)
    field(:start_time, :time)
    field(:end_time, :time)
    field(:available, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  `service_uuid` is never cast from attrs — the context passes it
  explicitly (ownership pattern, mirrors `phoenix_kit_calendar`).

  `time_unit` is the owning service's unit, so the changeset can require
  times for minute services and forbid them for day/night services.
  """
  def changeset(rule, attrs, time_unit) do
    rule
    |> cast(attrs, [:days_of_week, :date, :start_time, :end_time, :available])
    |> validate_days_of_week()
    |> validate_shape()
    |> validate_times(time_unit)
  end

  defp validate_days_of_week(changeset) do
    case get_field(changeset, :days_of_week) do
      nil ->
        changeset

      days when is_list(days) ->
        if days != [] and Enum.all?(days, &(&1 in 1..7)) do
          put_change(changeset, :days_of_week, Enum.sort(Enum.uniq(days)))
        else
          add_error(changeset, :days_of_week, "must be ISO weekday numbers (1-7)")
        end
    end
  end

  # A rule is either weekly (days_of_week) or a date override (date) —
  # at least one must be present so the rule applies to something.
  defp validate_shape(changeset) do
    days = get_field(changeset, :days_of_week)
    date = get_field(changeset, :date)

    if is_nil(days) and is_nil(date) do
      add_error(changeset, :days_of_week, "pick weekdays or a specific date")
    else
      changeset
    end
  end

  defp validate_times(changeset, time_unit) when time_unit in ["day", "night"] do
    start_t = get_field(changeset, :start_time)
    end_t = get_field(changeset, :end_time)

    if is_nil(start_t) and is_nil(end_t) do
      changeset
    else
      add_error(changeset, :start_time, "day-based services use whole days, not times")
    end
  end

  defp validate_times(changeset, _minutes) do
    changeset
    |> validate_required([:start_time, :end_time])
    |> validate_time_order()
  end

  defp validate_time_order(changeset) do
    start_t = get_field(changeset, :start_time)
    end_t = get_field(changeset, :end_time)

    if start_t && end_t && Time.compare(start_t, end_t) != :lt do
      add_error(changeset, :end_time, "must be after the start time")
    else
      changeset
    end
  end
end
