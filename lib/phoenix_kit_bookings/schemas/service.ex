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

  alias PhoenixKit.Utils.Slug

  @statuses ~w(active inactive trashed)
  @time_units ~w(minutes day night)
  @signup_policies ~w(anyone login_required)
  @price_pers ~w(booking hour day night)

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

    # Minutes before start until which a customer may self-cancel
    # (0 = cancellable right up to the start).
    field(:cancel_notice, :integer, default: 0)
    # Loose reference to a staff person (no FK — staff is optional).
    # Minute-unit bookings of the SAME provider block each other across
    # services. Cast normally — it's admin form input, not ownership.
    field(:provider_uuid, UUIDv7)
    # nil price = free/unpriced. Total = price × price_per units.
    field(:price, :decimal)
    field(:price_per, :string, default: "booking")
    field(:currency, :string, default: "EUR")
    # nil = no reminder email; else minutes before start.
    field(:reminder_minutes, :integer)

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
  def price_pers, do: @price_pers

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
      :require_approval,
      :cancel_notice,
      :provider_uuid,
      :price,
      :price_per,
      :currency,
      :reminder_minutes
    ])
    # Core's changeset glue, replacing a local generator whose slugify was
    # ASCII-only (`[^a-z0-9]` after downcase) — a Cyrillic or Greek name
    # produced "" and then FAILED the format validation below, so such a
    # service could not be created at all. Core romanizes instead, and also
    # probes for collisions, suffixing -2, -3 … until free — the old code
    # never checked, and `phoenix_kit_bookings_services_slug_index` is unique
    # (migrations/schema.ex:107), so a name collision was a raw constraint
    # error. `max_length: 160` matches the column and the length cap below;
    # the suffix respects it rather than overflowing.
    |> Slug.put_slug(:name, max_length: 160)
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
    |> validate_number(:cancel_notice, greater_than_or_equal_to: 0)
    |> validate_number(:reminder_minutes, greater_than: 0)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_inclusion(:price_per, @price_pers)
    |> validate_length(:currency, max: 10)
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
