defmodule PhoenixKitBookings.PriceOptions do
  @moduledoc """
  Per-service price options and who is entitled to them (see
  `PhoenixKitBookings.Schemas.PriceOption`).

  `entitled_options/2` is what the public flow offers; `entitled?/2` is the
  check the locked create re-runs on the option the customer sent. Mutations
  log an activity and broadcast on `Services.services_topic/0` like every
  other service-config change.
  """

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitBookings.{Activity, Services}
  alias PhoenixKitBookings.Schemas.{PriceOption, Service}

  @doc "All options of a service, by position then name."
  def list_options(service_uuid) do
    from(o in PriceOption,
      where: o.service_uuid == ^service_uuid,
      order_by: [asc: o.position, asc: o.name]
    )
    |> repo().all()
  end

  @doc "Active options of a service."
  def list_active_options(service_uuid) do
    from(o in PriceOption,
      where: o.service_uuid == ^service_uuid and o.active == true,
      order_by: [asc: o.position, asc: o.name]
    )
    |> repo().all()
  end

  @doc """
  The active options of `service` the customer may book at. `user` is a user
  struct, a user uuid, or nil (a guest sees only `everyone` options).
  """
  def entitled_options(%Service{} = service, user) do
    user = resolve_user(user)

    service.uuid
    |> list_active_options()
    |> Enum.filter(&entitled?(&1, user))
  end

  @doc "Fetches an option of a service; nil on miss, forged id or another service's."
  def get_option(service_uuid, option_uuid) when is_binary(option_uuid) do
    repo().get_by(PriceOption, uuid: option_uuid, service_uuid: service_uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_option(_service_uuid, _option_uuid), do: nil

  @doc """
  Whether `user` (a struct, a uuid or nil) may book at `option`. An inactive
  account is a guest here.
  """
  def entitled?(%PriceOption{entitlement: "everyone"}, _user), do: true

  def entitled?(%PriceOption{} = option, user) do
    case resolve_user(user) do
      %User{} = user -> user_active?(user) and entitled_user?(option, user)
      _ -> false
    end
  end

  defp entitled_user?(%PriceOption{entitlement: "users", user_uuids: uuids}, user),
    do: user.uuid in (uuids || [])

  defp entitled_user?(%PriceOption{entitlement: "role", role_name: role}, user)
       when is_binary(role),
       do: Roles.user_has_role?(user, role)

  defp entitled_user?(%PriceOption{entitlement: "flag", flag_key: key}, user)
       when is_binary(key),
       do: flag_set?(Map.get(user.custom_fields || %{}, key))

  defp entitled_user?(_option, _user), do: false

  # A membership-style flag: set means present and not an explicit "no".
  defp flag_set?(value) when value in [nil, false, "", "false", "0", 0, "no"], do: false
  defp flag_set?(_value), do: true

  defp user_active?(%User{is_active: false}), do: false
  defp user_active?(%User{}), do: true

  defp resolve_user(%User{} = user), do: user
  defp resolve_user(%{uuid: uuid}) when is_binary(uuid), do: Auth.get_user(uuid)
  defp resolve_user(uuid) when is_binary(uuid), do: Auth.get_user(uuid)
  defp resolve_user(_), do: nil

  # ── Mutations ────────────────────────────────────────────────────────

  def create_option(%Service{} = service, attrs, opts \\ []) do
    %PriceOption{}
    |> PriceOption.changeset(attrs)
    |> Ecto.Changeset.put_change(:service_uuid, service.uuid)
    |> repo().insert()
    |> tap_log("bookings.price_option_added", service.uuid, opts)
  end

  def update_option(%PriceOption{} = option, attrs, opts \\ []) do
    option
    |> PriceOption.changeset(attrs)
    |> repo().update()
    |> tap_log("bookings.price_option_updated", option.service_uuid, opts)
  end

  def delete_option(%PriceOption{} = option, opts \\ []) do
    option
    |> repo().delete()
    |> tap_log("bookings.price_option_removed", option.service_uuid, opts)
  end

  defp tap_log({:ok, option} = result, action, service_uuid, opts) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid],
      resource_type: "bookings_service",
      resource_uuid: service_uuid,
      metadata: %{"name" => option.name}
    )

    Services.broadcast_changed(service_uuid)
    result
  end

  defp tap_log(result, _action, _service_uuid, _opts), do: result

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
