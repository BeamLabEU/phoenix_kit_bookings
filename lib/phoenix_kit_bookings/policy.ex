defmodule PhoenixKitBookings.Policy do
  @moduledoc """
  Authorization + self-service rules for the admin surface, in one
  server-side module (every admin LiveView routes its reads and
  mutations through here — buttons are hidden AND actions re-checked).

  ## The permission model

  Core's sub-permission semantics (a sub implies its base) force the
  calendar module's orientation:

  - **base `"bookings"`** — access the bookings admin area, scoped to
    services YOU OWN. This is the key an owner grants to let a user run
    their own bookable services.
  - **sub `"bookings.manage_all"`** — site-wide: every service (owned or
    site-level), every reservation, and the module settings page.
    Owner/superadmin roles hold it implicitly.

  ## Self-service settings (owner-controlled, default OFF)

  - `bookings_user_services_enabled` (boolean, default `false`) — whether
    base-permission holders may CREATE services at all. Off = they can
    still manage services an admin assigned to them.
  - `bookings_max_services_per_user` (integer, default `1`; `0` =
    unlimited) — per-user creation cap.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBookings.Schemas.Service
  alias PhoenixKitBookings.Services

  @manage_all "bookings.manage_all"

  # ── Capability checks ────────────────────────────────────────────────

  @doc "Site-wide management (sub-permission, Owner/superadmin implicit)."
  def manage_all?(scope), do: Scope.can?(scope, @manage_all)

  @doc "True when the scope may manage this specific service."
  def can_manage?(scope, %Service{} = service) do
    manage_all?(scope) or owns?(scope, service)
  end

  defp owns?(scope, %Service{owner_uuid: owner_uuid}) do
    user_uuid = user_uuid(scope)
    not is_nil(owner_uuid) and not is_nil(user_uuid) and owner_uuid == user_uuid
  end

  @doc """
  True when the scope may create a new service: site-wide managers
  always; base-permission holders only when self-service is enabled and
  they are under the per-user cap.
  """
  def can_create?(scope) do
    cond do
      manage_all?(scope) -> true
      is_nil(user_uuid(scope)) -> false
      not user_services_enabled?() -> false
      true -> under_cap?(scope)
    end
  end

  defp under_cap?(scope) do
    case max_services_per_user() do
      0 -> true
      max -> Services.count_owned(user_uuid(scope)) < max
    end
  end

  # ── Settings ─────────────────────────────────────────────────────────

  def user_services_enabled? do
    Settings.get_boolean_setting("bookings_user_services_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def max_services_per_user do
    Settings.get_integer_setting("bookings_max_services_per_user", 1)
  rescue
    _ -> 1
  catch
    :exit, _ -> 1
  end

  # ── Scoped reads ─────────────────────────────────────────────────────

  @doc "Services this scope may see in the admin (all opts pass through)."
  def visible_services(scope, opts \\ []) do
    if manage_all?(scope) do
      Services.list_services(opts)
    else
      Services.list_services(Keyword.put(opts, :owner_uuid, user_uuid(scope)))
    end
  end

  @doc "Service UUIDs the scope may see — feeds the reservations filter."
  def visible_service_uuids(scope) do
    scope
    |> visible_services(include_trashed: true)
    |> Enum.map(& &1.uuid)
  end

  # ── Authorized mutations (LVs call these, never Services directly) ───

  @doc """
  Creates a service on behalf of `scope`. Site-wide managers create
  SITE services (no owner); base-permission holders create services
  owned by themselves (when allowed).
  """
  def create_service(scope, attrs) do
    if can_create?(scope) do
      owner = if manage_all?(scope), do: nil, else: user_uuid(scope)
      Services.create_service(attrs, actor_opts(scope) ++ [owner_uuid: owner])
    else
      {:error, :not_allowed}
    end
  end

  def update_service(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn ->
      Services.update_service(service, attrs, actor_opts(scope))
    end)
  end

  def set_status(scope, %Service{} = service, status) do
    authorized(scope, service, fn ->
      Services.set_status(service, status, actor_opts(scope))
    end)
  end

  def trash_service(scope, %Service{} = service) do
    authorized(scope, service, fn -> Services.trash_service(service, actor_opts(scope)) end)
  end

  def restore_service(scope, %Service{} = service) do
    authorized(scope, service, fn -> Services.restore_service(service, actor_opts(scope)) end)
  end

  def delete_service(scope, %Service{} = service) do
    authorized(scope, service, fn -> Services.delete_service(service, actor_opts(scope)) end)
  end

  def add_rule(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn -> Services.add_rule(service, attrs, actor_opts(scope)) end)
  end

  def add_unit(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn -> Services.add_unit(service, attrs, actor_opts(scope)) end)
  end

  def set_unit_active(scope, %Service{} = service, unit, active?) do
    authorized(scope, service, fn ->
      Services.set_unit_active(unit, active?, actor_opts(scope))
    end)
  end

  def delete_unit(scope, %Service{} = service, unit) do
    authorized(scope, service, fn -> Services.delete_unit(unit, actor_opts(scope)) end)
  end

  def delete_rule(scope, %Service{} = service, rule) do
    authorized(scope, service, fn -> Services.delete_rule(rule, actor_opts(scope)) end)
  end

  @doc "Booking lifecycle actions authorize against the booking's service."
  def confirm_booking(scope, booking) do
    with_booking_service(scope, booking, fn ->
      PhoenixKitBookings.Bookings.confirm_booking(booking, actor_opts(scope))
    end)
  end

  def cancel_booking(scope, booking, opts \\ []) do
    with_booking_service(scope, booking, fn ->
      PhoenixKitBookings.Bookings.cancel_booking(booking, actor_opts(scope) ++ opts)
    end)
  end

  # ── Plumbing ─────────────────────────────────────────────────────────

  defp authorized(scope, service, fun) do
    if can_manage?(scope, service), do: fun.(), else: {:error, :not_allowed}
  end

  defp with_booking_service(scope, booking, fun) do
    case Services.get_service(booking.service_uuid) do
      nil -> {:error, :not_allowed}
      service -> authorized(scope, service, fun)
    end
  end

  defp actor_opts(scope), do: [actor_uuid: user_uuid(scope)]

  defp user_uuid(scope) do
    case scope do
      %{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end
end
