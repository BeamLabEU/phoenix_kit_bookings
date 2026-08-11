defmodule PhoenixKitBookings.Schemas.Hold do
  @moduledoc """
  A short-lived capacity hold — created when a public visitor advances to
  the details step, so the seat they picked can't be sold out from under
  them while they type (the Cal.com `SelectedSlots` pattern).

  Same either/or time shape as bookings (DB CHECK). Expired holds are
  ignored by every capacity query and deleted lazily — no sweeper needed.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_holds" do
    field(:service_uuid, UUIDv7)
    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)
    field(:starts_on, :date)
    field(:ends_on, :date)
    field(:expires_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
