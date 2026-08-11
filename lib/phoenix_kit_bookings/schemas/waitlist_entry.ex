defmodule PhoenixKitBookings.Schemas.WaitlistEntry do
  @moduledoc """
  A waitlist signup: "email me when `date` frees up on this service".

  Release strategy is notify-all-first-to-book (the simplest of Vagaro's
  four modes and the fairest without payment pressure): when a
  cancellation frees capacity on a date, every `open` entry for that date
  gets an email and flips to `notified` — the booking page does the rest.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @statuses ~w(open notified removed)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_waitlist" do
    field(:service_uuid, UUIDv7)
    field(:date, :date)
    field(:customer_name, :string)
    field(:customer_email, :string)
    field(:status, :string, default: "open")

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc "`service_uuid` is stamped by the context, never cast."
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:date, :customer_name, :customer_email])
    |> validate_required([:date, :customer_name, :customer_email])
    |> validate_length(:customer_name, max: 255)
    |> validate_length(:customer_email, max: 255)
    |> validate_format(:customer_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
  end
end
