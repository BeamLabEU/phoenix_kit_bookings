defmodule PhoenixKitBookings.Schemas.RegularSlot do
  @moduledoc """
  Who usually has a time: a weekly slot of a service (`day_of_week`, with
  `start_time`/`end_time` for minute services, or the whole day) and its
  regular holder — an account (`user_uuid`) and/or an address
  (`customer_email`).

  It never blocks anyone. When somebody else books into it, the booking is
  created as usual, flagged in its `metadata["regular_slot_conflicts"]`, and
  the owner is told (`Bookings` → `RegularSlots.conflicts/2`).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_regular_slots" do
    field(:service_uuid, UUIDv7)
    field(:day_of_week, :integer)
    field(:start_time, :time)
    field(:end_time, :time)
    field(:user_uuid, UUIDv7)
    field(:customer_name, :string)
    field(:customer_email, :string)
    field(:notes, :string)
    field(:active, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "`service_uuid` is stamped by the context, never cast."
  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [
      :day_of_week,
      :start_time,
      :end_time,
      :user_uuid,
      :customer_name,
      :customer_email,
      :notes,
      :active
    ])
    |> update_change(:customer_email, &normalize_email/1)
    |> validate_required([:day_of_week])
    |> validate_number(:day_of_week, greater_than_or_equal_to: 1, less_than_or_equal_to: 7)
    |> validate_length(:customer_name, max: 255)
    |> validate_length(:customer_email, max: 255)
    |> validate_format(:customer_email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/,
      message: "must be a valid email address"
    )
    |> validate_holder()
    |> validate_times()
    |> check_constraint(:day_of_week, name: :bookings_regular_slot_day)
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(email) when is_binary(email) do
    case String.trim(email) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_holder(changeset) do
    if is_nil(get_field(changeset, :user_uuid)) and is_nil(get_field(changeset, :customer_email)) do
      add_error(changeset, :customer_email, "name the regular holder: an account or an email")
    else
      changeset
    end
  end

  # Both times or neither (neither = the whole day), start before end.
  defp validate_times(changeset) do
    start_t = get_field(changeset, :start_time)
    end_t = get_field(changeset, :end_time)

    cond do
      is_nil(start_t) and is_nil(end_t) ->
        changeset

      is_nil(start_t) or is_nil(end_t) ->
        add_error(changeset, :end_time, "give both times")

      Time.compare(start_t, end_t) != :lt ->
        add_error(changeset, :end_time, "must be after the start time")

      true ->
        changeset
    end
  end
end
