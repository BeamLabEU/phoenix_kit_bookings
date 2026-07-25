defmodule PhoenixKitBookings.Services do
  @moduledoc """
  CRUD for bookable services and their availability rules.

  Every mutation logs an Activity entry (actor via `opts[:actor_uuid]`,
  passed down from the LiveView layer) and broadcasts
  `{:bookings_service_changed, service_uuid}` on `services_topic/0` so
  admin lists and public pickers stay live.
  """

  import Ecto.Query

  alias PhoenixKitBookings.Activity
  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Service}

  @services_topic "phoenix_kit_bookings:services"

  @doc "PubSub topic announcing service config changes."
  def services_topic, do: @services_topic

  # ── Queries ──────────────────────────────────────────────────────────

  @doc """
  Lists services. Trashed rows are excluded unless `status: "trashed"` or
  `include_trashed: true` is passed. Options: `:status`,
  `:include_trashed`, `:owner_uuid` (only services owned by that user —
  `Policy.visible_services/2` uses this for base-permission holders).
  """
  def list_services(opts \\ []) do
    base = from(s in Service, order_by: [asc: s.name])

    query =
      cond do
        status = opts[:status] -> from(s in base, where: s.status == ^status)
        opts[:include_trashed] -> base
        true -> from(s in base, where: s.status != "trashed")
      end

    query =
      case opts[:owner_uuid] do
        nil -> query
        owner_uuid -> from(s in query, where: s.owner_uuid == ^owner_uuid)
      end

    repo().all(query)
  end

  @doc "Non-trashed services owned by a user (the self-service cap check)."
  def count_owned(nil), do: 0

  def count_owned(owner_uuid) do
    from(s in Service, where: s.owner_uuid == ^owner_uuid and s.status != "trashed")
    |> repo().aggregate(:count)
  end

  @doc "Active services for the public listing."
  def list_public_services do
    list_services(status: "active")
  end

  @doc "Fetches a service by UUID; nil on miss or forged id."
  def get_service(uuid) do
    repo().get(Service, uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_service!(uuid), do: repo().get!(Service, uuid)

  @doc "Fetches an ACTIVE service by public slug (the public booking path)."
  def get_active_service_by_slug(slug) when is_binary(slug) do
    repo().get_by(Service, slug: slug, status: "active")
  end

  @doc "Counts services per status — powers the admin tabs."
  def count_by_status do
    from(s in Service, group_by: s.status, select: {s.status, count(s.uuid)})
    |> repo().all()
    |> Map.new()
  end

  # ── Mutations ────────────────────────────────────────────────────────

  @doc """
  Creates a service. `opts[:owner_uuid]` stamps the owning user (nil = a
  site-wide service) — deliberately an option, never cast from attrs.
  """
  def create_service(attrs, opts \\ []) do
    %Service{}
    |> Service.changeset(attrs)
    |> maybe_stamp_owner(opts[:owner_uuid])
    |> repo().insert()
    |> tap_log("bookings.service_created", opts)
    |> tap_broadcast()
  end

  defp maybe_stamp_owner(changeset, nil), do: changeset

  defp maybe_stamp_owner(changeset, owner_uuid),
    do: Ecto.Changeset.put_change(changeset, :owner_uuid, owner_uuid)

  def update_service(%Service{} = service, attrs, opts \\ []) do
    service
    |> Service.changeset(attrs)
    |> repo().update()
    |> tap_log("bookings.service_updated", opts)
    |> tap_broadcast()
  end

  @doc "Controlled status flip (active / inactive)."
  def set_status(%Service{} = service, status, opts \\ [])
      when status in ["active", "inactive"] do
    service
    |> Service.status_changeset(status)
    |> repo().update()
    |> tap_log("bookings.service_status_changed", opts)
    |> tap_broadcast()
  end

  @doc "Soft-delete (workspace status-sentinel convention)."
  def trash_service(%Service{} = service, opts \\ []) do
    service
    |> Service.status_changeset("trashed")
    |> repo().update()
    |> tap_log("bookings.service_trashed", opts)
    |> tap_broadcast()
  end

  def restore_service(%Service{} = service, opts \\ []) do
    service
    |> Service.status_changeset("active")
    |> repo().update()
    |> tap_log("bookings.service_restored", opts)
    |> tap_broadcast()
  end

  @doc """
  Permanent delete — Trash view only. Cascades to availability rules and
  bookings (DB `ON DELETE CASCADE`).
  """
  def delete_service(%Service{} = service, opts \\ []) do
    service
    |> repo().delete()
    |> tap_log("bookings.service_deleted", opts)
    |> tap_broadcast()
  end

  # ── Availability rules ───────────────────────────────────────────────

  @doc "Rules of a service, overrides first, then weekly rules."
  def list_rules(%Service{uuid: service_uuid}), do: list_rules(service_uuid)

  def list_rules(service_uuid) do
    from(r in AvailabilityRule,
      where: r.service_uuid == ^service_uuid,
      order_by: [asc_nulls_last: r.date, asc: r.start_time, asc: r.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Adds one availability rule. `service_uuid` is stamped explicitly — never
  cast from attrs.
  """
  def add_rule(%Service{} = service, attrs, opts \\ []) do
    %AvailabilityRule{}
    |> AvailabilityRule.changeset(attrs, service.time_unit)
    |> Ecto.Changeset.put_change(:service_uuid, service.uuid)
    |> repo().insert()
    |> tap_log("bookings.availability_rule_added", opts,
      resource_type: "bookings_service",
      resource_uuid: service.uuid
    )
    |> tap_broadcast_service(service.uuid)
  end

  def delete_rule(%AvailabilityRule{} = rule, opts \\ []) do
    rule
    |> repo().delete()
    |> tap_log("bookings.availability_rule_removed", opts,
      resource_type: "bookings_service",
      resource_uuid: rule.service_uuid
    )
    |> tap_broadcast_service(rule.service_uuid)
  end

  # ── Plumbing ─────────────────────────────────────────────────────────

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp tap_log(result, action, opts, extra \\ [])

  defp tap_log({:ok, record} = result, action, opts, extra) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid],
      resource_type: Keyword.get(extra, :resource_type, "bookings_service"),
      resource_uuid: Keyword.get(extra, :resource_uuid, record.uuid),
      metadata: %{"name" => Map.get(record, :name)}
    )

    result
  end

  defp tap_log(result, _action, _opts, _extra), do: result

  defp tap_broadcast({:ok, %Service{uuid: uuid}} = result) do
    broadcast_changed(uuid)
    result
  end

  defp tap_broadcast(result), do: result

  defp tap_broadcast_service({:ok, _} = result, service_uuid) do
    broadcast_changed(service_uuid)
    result
  end

  defp tap_broadcast_service(result, _service_uuid), do: result

  defp broadcast_changed(service_uuid) do
    case PhoenixKit.Config.pubsub_server() do
      nil ->
        :ok

      pubsub ->
        Phoenix.PubSub.broadcast(
          pubsub,
          @services_topic,
          {:bookings_service_changed, service_uuid}
        )
    end
  rescue
    _ -> :ok
  end
end
