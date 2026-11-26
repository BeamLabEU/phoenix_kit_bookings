defmodule PhoenixKitBookings.Schemas.PriceOption do
  @moduledoc """
  An extra rate of a service that a customer can be entitled to — a
  trainer's solo-lesson rate, a members' price, a staff discount.

  The service's own `price` stays the default for everyone; an option is an
  alternative the booking flow offers to the customers it is meant for:

  - `entitlement: "everyone"` — any customer (a plain second rate).
  - `"users"` — only the accounts in `user_uuids`.
  - `"role"` — accounts holding the core role `role_name`.
  - `"flag"` — accounts whose `custom_fields[flag_key]` is set (a
    membership-style flag a host app writes on the user).

  Every entitlement but `everyone` needs a logged-in customer. The check is
  `PhoenixKitBookings.PriceOptions.entitled?/2`, and the locked create
  re-runs it, so a forged option id from the client books nothing.

  `price_per` nil means the service's own `price_per`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @entitlements ~w(everyone users role flag)
  @price_pers ~w(booking hour day night)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_price_options" do
    field(:service_uuid, UUIDv7)
    field(:name, :string)
    field(:description, :string)
    field(:price, :decimal)
    field(:price_per, :string)
    field(:entitlement, :string, default: "everyone")
    field(:user_uuids, {:array, UUIDv7}, default: [])
    field(:role_name, :string)
    field(:flag_key, :string)
    field(:active, :boolean, default: true)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def entitlements, do: @entitlements

  @doc "`service_uuid` is stamped by the context, never cast."
  def changeset(option, attrs) do
    option
    |> cast(attrs, [
      :name,
      :description,
      :price,
      :price_per,
      :entitlement,
      :user_uuids,
      :role_name,
      :flag_key,
      :active,
      :position
    ])
    |> update_change(:price_per, &blank_to_nil/1)
    |> update_change(:role_name, &blank_to_nil/1)
    |> update_change(:flag_key, &blank_to_nil/1)
    |> validate_required([:name, :price, :entitlement])
    |> validate_length(:name, max: 255)
    |> validate_number(:price, greater_than_or_equal_to: 0, less_than: 10_000_000_000)
    |> validate_inclusion(:entitlement, @entitlements)
    |> validate_inclusion(:price_per, @price_pers)
    |> validate_length(:role_name, max: 100)
    |> validate_length(:flag_key, max: 100)
    |> validate_entitlement_target()
    |> check_constraint(:entitlement, name: :bookings_price_option_entitlement)
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp blank_to_nil(value), do: value

  # Each restricted entitlement names who it is for.
  defp validate_entitlement_target(changeset) do
    case get_field(changeset, :entitlement) do
      "users" ->
        if get_field(changeset, :user_uuids) in [nil, []],
          do: add_error(changeset, :user_uuids, "pick at least one user"),
          else: changeset

      "role" ->
        validate_required(changeset, [:role_name])

      "flag" ->
        validate_required(changeset, [:flag_key])

      _ ->
        changeset
    end
  end
end
