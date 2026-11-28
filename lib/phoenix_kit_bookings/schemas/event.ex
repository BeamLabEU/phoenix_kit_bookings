defmodule PhoenixKitBookings.Schemas.Event do
  @moduledoc """
  A dated occurrence of a service with its own capacity — a yoga class on
  Tuesday 18:00, a guided tour on Saturday. What the public schedule lists.

  - `service_uuid` (required) — what it is; signing up creates an ordinary
    booking of that service stamped with `event_uuid`, so the seat shows in
    the reservations list and the room stays busy for the service's own
    picker.
  - `host_profile_uuid` — who runs it (falls back to the service's profile).
  - `capacity` — seats at the event; nil = the service's capacity.
  - `price` — nil = the service's price for the event's length.
  - `status` — `scheduled` | `cancelled`; `public: false` keeps it off the
    public schedule (bookable by link from the admin only).
  - `ignore_service_capacity` (kept in `settings`) — by default a sign-up is
    also refused while the service's own bookings fill all its seats at the
    event's time; `true` lets the event sell its seats regardless (a class
    in a hall the service's other bookings do not really share).

  Times are true UTC, shown in the site frame.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @statuses ~w(scheduled cancelled)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_events" do
    field(:service_uuid, UUIDv7)
    field(:host_profile_uuid, UUIDv7)
    field(:title, :string)
    field(:description, :string)
    field(:location, :string)
    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)
    field(:capacity, :integer)
    field(:price, :decimal)
    field(:status, :string, default: "scheduled")
    field(:public, :boolean, default: true)
    field(:settings, :map, default: %{})
    field(:ignore_service_capacity, :boolean, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc """
  Casts the editable fields. `service_uuid` is cast here because an event is
  admin input; the context checks the actor may manage that service.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :service_uuid,
      :host_profile_uuid,
      :title,
      :description,
      :location,
      :starts_at,
      :ends_at,
      :capacity,
      :price,
      :status,
      :public,
      :ignore_service_capacity
    ])
    |> put_ignore_service_capacity()
    |> validate_required([:service_uuid, :title, :starts_at, :ends_at, :status])
    |> validate_length(:title, max: 255)
    |> validate_length(:location, max: 255)
    |> validate_number(:capacity, greater_than: 0)
    # NUMERIC(12,2): ten integer digits, after rounding to cents.
    |> validate_number(:price,
      greater_than_or_equal_to: 0,
      less_than: Decimal.new("9999999999.995")
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_order()
    |> check_constraint(:ends_at, name: :bookings_event_order)
    |> foreign_key_constraint(:host_profile_uuid)
    |> foreign_key_constraint(:service_uuid)
  end

  @doc "Whether the event sells its seats whatever the service's own bookings take."
  def ignore_service_capacity?(%__MODULE__{settings: settings}),
    do: Map.get(settings || %{}, "ignore_service_capacity") == true

  defp put_ignore_service_capacity(changeset) do
    case fetch_change(changeset, :ignore_service_capacity) do
      {:ok, value} ->
        settings = get_field(changeset, :settings) || %{}

        put_change(
          changeset,
          :settings,
          Map.put(settings, "ignore_service_capacity", value == true)
        )

      :error ->
        changeset
    end
  end

  defp validate_order(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(starts_at, ends_at) != :lt do
      add_error(changeset, :ends_at, "must be after the start")
    else
      changeset
    end
  end
end
