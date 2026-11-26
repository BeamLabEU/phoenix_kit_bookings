defmodule PhoenixKitBookings.HostProfiles do
  @moduledoc """
  Public host profiles — the people who run services and events (see
  `PhoenixKitBookings.Schemas.HostProfile`). Mutations log an activity
  (`bookings.host_profile_*`, resource `bookings_host_profile`) and
  broadcast on `Services.services_topic/0`.
  """

  import Ecto.Query

  alias PhoenixKitBookings.{Activity, Services}
  alias PhoenixKitBookings.Schemas.{HostProfile, Service}

  @doc "Every profile, by position then name. `status:` filters."
  def list_profiles(opts \\ []) do
    from(h in HostProfile, order_by: [asc: h.position, asc: h.name])
    |> maybe_status(opts[:status])
    |> repo().all()
  end

  defp maybe_status(query, nil), do: query
  defp maybe_status(query, status), do: from(h in query, where: h.status == ^status)

  @doc "Active profiles — the public list."
  def list_public_profiles, do: list_profiles(status: "active")

  def get_profile(uuid) when is_binary(uuid) do
    repo().get(HostProfile, uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_profile(_), do: nil

  @doc "An ACTIVE profile by slug (the public page)."
  def get_public_profile_by_slug(slug) when is_binary(slug) do
    repo().get_by(HostProfile, slug: slug, status: "active")
  end

  @doc "Profiles keyed by uuid — batch lookup for lists."
  def profiles_by_uuid(uuids) when is_list(uuids) do
    uuids = uuids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(h in HostProfile, where: h.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  @doc "Active, publicly listed services a profile runs."
  def list_public_services(%HostProfile{uuid: uuid}) do
    from(s in Service,
      where: s.host_profile_uuid == ^uuid and s.status == "active",
      order_by: [asc: s.name]
    )
    |> repo().all()
  end

  def create_profile(attrs, opts \\ []) do
    %HostProfile{}
    |> HostProfile.changeset(attrs)
    |> repo().insert()
    |> tap_log("bookings.host_profile_created", opts)
  end

  def update_profile(%HostProfile{} = profile, attrs, opts \\ []) do
    profile
    |> HostProfile.changeset(attrs)
    |> repo().update()
    |> tap_log("bookings.host_profile_updated", opts)
  end

  @doc "Deletes a profile; services and events keep running without one."
  def delete_profile(%HostProfile{} = profile, opts \\ []) do
    profile
    |> repo().delete()
    |> tap_log("bookings.host_profile_deleted", opts)
  end

  defp tap_log({:ok, profile} = result, action, opts) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid],
      resource_type: "bookings_host_profile",
      resource_uuid: profile.uuid,
      metadata: %{"name" => profile.name}
    )

    Services.broadcast_changed(nil)
    result
  end

  defp tap_log(result, _action, _opts), do: result

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
