defmodule PhoenixKitBookings.Schemas.Unit do
  @moduledoc """
  A named bookable unit of a service — Room 101, Chair 2, Court A.

  When a service has ANY active units, its capacity becomes the count of
  active units (overriding `seats`) and every confirmed/pending booking is
  auto-assigned the least-loaded free unit inside the locked create
  (`PhoenixKitBookings.Bookings`). Services without units keep the pooled
  `seats` counter (Checkfront/Planyo-style) — the Booqable `trackable`
  dichotomy, deferred per service.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_units" do
    field(:service_uuid, UUIDv7)
    field(:name, :string)
    field(:active, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "`service_uuid` is stamped by the context, never cast."
  def changeset(unit, attrs) do
    unit
    |> cast(attrs, [:name, :active])
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
  end
end
