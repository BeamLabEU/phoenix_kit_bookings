defmodule PhoenixKitBookings.Schemas.Service do
  @moduledoc """
  A bookable offer — the universal unit of configuration.

  One install can mix services with entirely different booking shapes; the
  shape is per-service config, never a module-level setting:

  - `time_unit: "minutes"` — timed bookings. `flexible_duration: false`
    gives fixed slots on a `slot_interval` grid (massage on the hour);
    `flexible_duration: true` gives a free-form range picker bounded by
    `min_duration`/`max_duration` (`max_duration: nil` = unbounded — gym).
  - `time_unit: "day"` / `"night"` — date-range bookings (hotel). `night`
    differs from `day` only in presentation/pricing semantics (checkout is
    the exclusive end date in both). `min_stay`/`max_stay` bound the range;
    `checkin_time`/`checkout_time` are display attributes, never part of
    the availability math.

  `seats` is pooled capacity per slot/date (1 = exclusive use — a single
  massage table or 1 room; 7 = seven rooms of this type; 20 = gym floor).

  `signup_policy` gates the public flow (`"anyone"` allows guest bookings,
  `"login_required"` requires an authenticated user); `require_approval`
  makes new bookings start as `pending` (RSVP-style) instead of instantly
  `confirmed`.

  Soft-delete: `status: "trashed"` sentinel (workspace convention);
  `"inactive"` hides the service from the public page while keeping it
  bookable by admins.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @statuses ~w(active inactive trashed)
  @time_units ~w(minutes day night)
  @signup_policies ~w(anyone login_required)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_services" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:status, :string, default: "active")

    field(:time_unit, :string, default: "minutes")
    field(:duration, :integer, default: 60)
    field(:slot_interval, :integer)
    field(:flexible_duration, :boolean, default: false)
    field(:min_duration, :integer)
    field(:max_duration, :integer)
    field(:buffer_before, :integer, default: 0)
    field(:buffer_after, :integer, default: 0)
    field(:min_notice, :integer, default: 0)
    field(:max_advance, :integer)
    field(:seats, :integer, default: 1)
    field(:min_stay, :integer)
    field(:max_stay, :integer)
    field(:checkin_time, :time)
    field(:checkout_time, :time)

    field(:signup_policy, :string, default: "anyone")
    field(:require_approval, :boolean, default: false)
    # nil = a site-wide service; set = a user-owned service (the
    # self-service feature). NEVER cast from attrs — stamped by
    # `Services.create_service/2` via `opts[:owner_uuid]`.
    field(:owner_uuid, UUIDv7)
    field(:settings, :map, default: %{})

    has_many(:availability_rules, PhoenixKitBookings.Schemas.AvailabilityRule,
      foreign_key: :service_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def time_units, do: @time_units
  def signup_policies, do: @signup_policies

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :time_unit,
      :duration,
      :slot_interval,
      :flexible_duration,
      :min_duration,
      :max_duration,
      :buffer_before,
      :buffer_after,
      :min_notice,
      :max_advance,
      :seats,
      :min_stay,
      :max_stay,
      :checkin_time,
      :checkout_time,
      :signup_policy,
      :require_approval
    ])
    |> maybe_generate_slug()
    |> validate_required([:name, :slug, :time_unit, :duration, :seats, :signup_policy])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 160)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must be lowercase letters, digits and hyphens"
    )
    |> validate_inclusion(:time_unit, @time_units)
    |> validate_inclusion(:signup_policy, @signup_policies)
    |> validate_number(:duration, greater_than: 0)
    |> validate_number(:slot_interval, greater_than: 0)
    |> validate_number(:min_duration, greater_than: 0)
    |> validate_number(:max_duration, greater_than: 0)
    |> validate_number(:buffer_before, greater_than_or_equal_to: 0)
    |> validate_number(:buffer_after, greater_than_or_equal_to: 0)
    |> validate_number(:min_notice, greater_than_or_equal_to: 0)
    |> validate_number(:max_advance, greater_than: 0)
    |> validate_number(:seats, greater_than: 0)
    |> validate_number(:min_stay, greater_than: 0)
    |> validate_number(:max_stay, greater_than: 0)
    |> validate_duration_bounds()
    |> validate_stay_bounds()
    |> unique_constraint(:slug, name: :phoenix_kit_bookings_services_slug_index)
    |> check_constraint(:time_unit, name: :bookings_service_time_unit)
    |> check_constraint(:signup_policy, name: :bookings_service_signup_policy)
    |> check_constraint(:seats, name: :bookings_service_seats_positive)
    |> check_constraint(:duration, name: :bookings_service_duration_positive)
  end

  @doc "Status transitions are controlled — never cast from attrs."
  def status_changeset(service, status) when status in @statuses do
    change(service, status: status)
  end

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _slug ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 160)
  end

  defp validate_duration_bounds(changeset) do
    min = get_field(changeset, :min_duration)
    max = get_field(changeset, :max_duration)

    if is_integer(min) and is_integer(max) and max < min do
      add_error(changeset, :max_duration, "must be greater than or equal to minimum duration")
    else
      changeset
    end
  end

  defp validate_stay_bounds(changeset) do
    min = get_field(changeset, :min_stay)
    max = get_field(changeset, :max_stay)

    if is_integer(min) and is_integer(max) and max < min do
      add_error(changeset, :max_stay, "must be greater than or equal to minimum stay")
    else
      changeset
    end
  end
end
