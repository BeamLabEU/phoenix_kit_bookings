defmodule PhoenixKitBookings.Schemas.HostProfile do
  @moduledoc """
  The public card of a person who runs services and events — a trainer, a
  guide, a teacher. Shown on the public schedule and on its own page
  (`/bookings/hosts/:slug`).

  `user_uuid` optionally links the account behind the profile; `provider_uuid`
  is the same loose staff reference services carry (no FK). Only `active`
  profiles are public.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKit.Utils.Slug

  @statuses ~w(active inactive)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_host_profiles" do
    field(:name, :string)
    field(:slug, :string)
    field(:headline, :string)
    field(:bio, :string)
    field(:photo_url, :string)
    field(:user_uuid, UUIDv7)
    field(:provider_uuid, UUIDv7)
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)
    field(:settings, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :name,
      :slug,
      :headline,
      :bio,
      :photo_url,
      :user_uuid,
      :provider_uuid,
      :status,
      :position
    ])
    |> Slug.put_slug(:name, max_length: 160)
    |> validate_required([:name, :slug, :status])
    |> validate_length(:name, max: 255)
    |> validate_length(:headline, max: 255)
    |> validate_length(:slug, max: 160)
    |> validate_format(:slug, ~r/\A[a-z0-9][a-z0-9-]*\z/,
      message: "must be lowercase letters, digits and hyphens"
    )
    |> validate_format(:photo_url, ~r{\Ahttps?://\S+\z}, message: "must be an http(s) URL")
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug, name: :phoenix_kit_bookings_host_profiles_slug_index)
  end
end
