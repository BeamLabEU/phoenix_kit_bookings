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
  alias PhoenixKitBookings.{Events, HostProfiles, ICalImport, PriceOptions, RegularSlots}
  alias PhoenixKitBookings.Schemas.{Event, HostProfile, PriceOption, RegularSlot, Service}
  alias PhoenixKitBookings.Services
  alias PhoenixKitWeb.Actor

  @base "bookings"
  @manage_all "bookings.manage_all"

  # ── Capability checks ────────────────────────────────────────────────

  @doc "Site-wide management (sub-permission, Owner/superadmin implicit)."
  def manage_all?(scope), do: Scope.can?(scope, @manage_all)

  @doc "True when the scope may manage this specific service."
  def can_manage?(scope, %Service{} = service) do
    manage_all?(scope) or owns?(scope, service)
  end

  defp owns?(scope, %Service{owner_uuid: owner_uuid}) do
    user_uuid = Actor.uuid(scope)

    not is_nil(owner_uuid) and not is_nil(user_uuid) and owner_uuid == user_uuid and
      Scope.can?(scope, @base)
  end

  @doc """
  True when the scope may create a new service: site-wide managers
  always; base-permission holders only when self-service is enabled and
  they are under the per-user cap.
  """
  def can_create?(scope) do
    cond do
      manage_all?(scope) -> true
      is_nil(Actor.uuid(scope)) -> false
      not user_services_enabled?() -> false
      true -> under_cap?(scope)
    end
  end

  defp under_cap?(scope) do
    case max_services_per_user() do
      0 -> true
      max -> Services.count_owned(Actor.uuid(scope)) < max
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
    cond do
      manage_all?(scope) -> Services.list_services(opts)
      # `list_services/1` reads a nil owner as "no filter".
      is_nil(Actor.uuid(scope)) -> []
      true -> Services.list_services(Keyword.put(opts, :owner_uuid, Actor.uuid(scope)))
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
      owner = if manage_all?(scope), do: nil, else: Actor.uuid(scope)
      Services.create_service(attrs, Actor.opts(scope) ++ [owner_uuid: owner])
    else
      {:error, :not_allowed}
    end
  end

  def update_service(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn ->
      Services.update_service(service, attrs, Actor.opts(scope))
    end)
  end

  def set_status(scope, %Service{} = service, status) do
    authorized(scope, service, fn ->
      Services.set_status(service, status, Actor.opts(scope))
    end)
  end

  def trash_service(scope, %Service{} = service) do
    authorized(scope, service, fn -> Services.trash_service(service, Actor.opts(scope)) end)
  end

  @doc """
  Restores a trashed service. A trashed service does not count against the
  per-user cap, so a base-permission holder restoring one is creating one.
  """
  def restore_service(scope, %Service{} = service) do
    authorized(scope, service, fn ->
      if manage_all?(scope) or under_cap?(scope) do
        Services.restore_service(service, Actor.opts(scope))
      else
        {:error, :not_allowed}
      end
    end)
  end

  def delete_service(scope, %Service{} = service) do
    authorized(scope, service, fn -> Services.delete_service(service, Actor.opts(scope)) end)
  end

  def add_rule(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn -> Services.add_rule(service, attrs, Actor.opts(scope)) end)
  end

  def add_unit(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn -> Services.add_unit(service, attrs, Actor.opts(scope)) end)
  end

  def set_unit_active(scope, %Service{} = service, unit, active?) do
    authorized(scope, service, fn ->
      Services.set_unit_active(unit, active?, Actor.opts(scope))
    end)
  end

  def delete_unit(scope, %Service{} = service, unit) do
    authorized(scope, service, fn -> Services.delete_unit(unit, Actor.opts(scope)) end)
  end

  def delete_rule(scope, %Service{} = service, rule) do
    authorized(scope, service, fn -> Services.delete_rule(rule, Actor.opts(scope)) end)
  end

  @doc """
  Booking lifecycle actions authorize against the booking's service.
  `opts` pass through to the context (e.g. `notify: false`, `reason:`).
  """
  def confirm_booking(scope, booking, opts \\ []) do
    with_booking_service(scope, booking, fn ->
      PhoenixKitBookings.Bookings.confirm_booking(booking, Actor.opts(scope) ++ opts)
    end)
  end

  def cancel_booking(scope, booking, opts \\ []) do
    with_booking_service(scope, booking, fn ->
      PhoenixKitBookings.Bookings.cancel_booking(booking, Actor.opts(scope) ++ opts)
    end)
  end

  # ── Price options, regular slots, iCal ──────────────────────────────

  def add_price_option(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn ->
      PriceOptions.create_option(service, attrs, Actor.opts(scope))
    end)
  end

  def update_price_option(scope, %Service{} = service, %PriceOption{} = option, attrs) do
    authorized_child(scope, service, option, fn ->
      PriceOptions.update_option(option, attrs, Actor.opts(scope))
    end)
  end

  def delete_price_option(scope, %Service{} = service, %PriceOption{} = option) do
    authorized_child(scope, service, option, fn ->
      PriceOptions.delete_option(option, Actor.opts(scope))
    end)
  end

  def add_regular_slot(scope, %Service{} = service, attrs) do
    authorized(scope, service, fn ->
      RegularSlots.create_slot(service, attrs, Actor.opts(scope))
    end)
  end

  def delete_regular_slot(scope, %Service{} = service, %RegularSlot{} = slot) do
    authorized_child(scope, service, slot, fn ->
      RegularSlots.delete_slot(slot, Actor.opts(scope))
    end)
  end

  @doc "Fetches and imports the service's iCal feed now (`ICalImport.sync_service/2`)."
  def sync_ical(scope, %Service{} = service) do
    authorized(scope, service, fn ->
      ICalImport.sync_service(service, Actor.opts(scope))
    end)
  end

  # ── Events and host profiles ─────────────────────────────────────────

  @doc "Events of the services this scope may see (all opts pass through)."
  def visible_events(scope, opts \\ []) do
    if manage_all?(scope) do
      Events.list_events(opts)
    else
      Events.list_events(Keyword.put(opts, :service_uuids, visible_service_uuids(scope)))
    end
  end

  @doc "Creates an event of a service the scope manages."
  def create_event(scope, attrs) do
    with_attr_service(scope, attrs, fn -> Events.create_event(attrs, Actor.opts(scope)) end)
  end

  @doc """
  Updates an event. Both its current service and, when the attrs move it,
  the new one must be manageable.
  """
  def update_event(scope, %Event{} = event, attrs) do
    with_event_service(scope, event, fn ->
      with_attr_service(scope, attrs, fn ->
        Events.update_event(event, attrs, Actor.opts(scope))
      end)
    end)
  end

  def cancel_event(scope, %Event{} = event, opts \\ []) do
    with_event_service(scope, event, fn ->
      Events.cancel_event(event, Actor.opts(scope) ++ opts)
    end)
  end

  def delete_event(scope, %Event{} = event) do
    with_event_service(scope, event, fn -> Events.delete_event(event, Actor.opts(scope)) end)
  end

  @doc "Host profiles are site-wide: `bookings.manage_all` only."
  def create_host_profile(scope, attrs) do
    if manage_all?(scope),
      do: HostProfiles.create_profile(attrs, Actor.opts(scope)),
      else: {:error, :not_allowed}
  end

  def update_host_profile(scope, %HostProfile{} = profile, attrs) do
    if manage_all?(scope),
      do: HostProfiles.update_profile(profile, attrs, Actor.opts(scope)),
      else: {:error, :not_allowed}
  end

  def delete_host_profile(scope, %HostProfile{} = profile) do
    if manage_all?(scope),
      do: HostProfiles.delete_profile(profile, Actor.opts(scope)),
      else: {:error, :not_allowed}
  end

  # ── Plumbing ─────────────────────────────────────────────────────────

  # A child row (option, slot) must belong to the service it is acted on via.
  defp authorized_child(scope, service, %{service_uuid: service_uuid}, fun) do
    if service_uuid == service.uuid,
      do: authorized(scope, service, fun),
      else: {:error, :not_allowed}
  end

  # Judged on the event as stored, not the struct the caller holds: the
  # event may have moved to another service since that page was loaded.
  defp with_event_service(scope, %Event{uuid: uuid}, fun) do
    with %Event{service_uuid: service_uuid} <- Events.get_event(uuid),
         %Service{} = service <- Services.get_service(service_uuid) do
      authorized(scope, service, fun)
    else
      _ -> {:error, :not_allowed}
    end
  end

  # The service an event's attrs name. Absent (an update that keeps it) is
  # fine; a named one must exist and be manageable.
  defp with_attr_service(scope, attrs, fun) do
    case attrs["service_uuid"] || attrs[:service_uuid] do
      blank when blank in [nil, ""] ->
        fun.()

      uuid ->
        case Services.get_service(uuid) do
          nil -> {:error, :not_allowed}
          service -> authorized(scope, service, fun)
        end
    end
  end

  # A stored service is judged as it is now, not as the caller's struct
  # says: an admin page holds its struct from mount, and the owner may have
  # changed since.
  defp authorized(scope, %Service{uuid: uuid}, fun) when is_binary(uuid) do
    case Services.get_service(uuid) do
      nil -> {:error, :not_allowed}
      current -> if can_manage?(scope, current), do: fun.(), else: {:error, :not_allowed}
    end
  end

  defp authorized(scope, service, fun) do
    if can_manage?(scope, service), do: fun.(), else: {:error, :not_allowed}
  end

  defp with_booking_service(scope, booking, fun) do
    case Services.get_service(booking.service_uuid) do
      nil -> {:error, :not_allowed}
      service -> authorized(scope, service, fun)
    end
  end
end
