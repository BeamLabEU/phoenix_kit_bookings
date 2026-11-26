defmodule PhoenixKitBookings.Events do
  @moduledoc """
  Scheduled events — dated occurrences of a service with their own capacity
  (see `PhoenixKitBookings.Schemas.Event`) — and the public schedule built
  from them.

  Signing up is `Bookings.create_event_booking/3`. Cancelling an event
  cancels its active bookings (each customer is emailed unless
  `notify: false`). Mutations log `bookings.event_*` (resource
  `bookings_event`) and broadcast on `Services.services_topic/0` and the
  service's booking topic.
  """

  import Ecto.Query

  alias PhoenixKitBookings.{Activity, Bookings, Services}
  alias PhoenixKitBookings.Schemas.{Booking, Event, Service}

  @doc """
  Events for the admin, by start. Options: `:service_uuids` (restrict to
  visible services), `:upcoming` (not yet ended), `:status`, `:limit`
  (default 200).
  """
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(e in Event, order_by: [asc: e.starts_at], limit: ^limit)
    |> maybe_services(opts[:service_uuids])
    |> maybe_status(opts[:status])
    |> maybe_upcoming(opts[:upcoming], opts[:now])
    |> repo().all()
  end

  @doc """
  The public schedule: scheduled, public events of active services that have
  not started, soonest first. Options: `:host_profile_uuid`, `:service_uuid`,
  `:until` (a DateTime), `:limit` (default 100), `:now`.
  """
  def list_public_upcoming(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 100)

    query =
      from(e in Event,
        join: s in Service,
        on: s.uuid == e.service_uuid,
        where: e.status == "scheduled" and e.public == true,
        where: s.status == "active",
        where: e.starts_at > ^now,
        order_by: [asc: e.starts_at],
        limit: ^limit
      )

    query
    |> maybe_host(opts[:host_profile_uuid])
    |> maybe_service(opts[:service_uuid])
    |> maybe_until(opts[:until])
    |> repo().all()
  end

  defp maybe_host(query, nil), do: query

  defp maybe_host(query, uuid) do
    from([e, s] in query,
      where:
        e.host_profile_uuid == ^uuid or
          (is_nil(e.host_profile_uuid) and s.host_profile_uuid == ^uuid)
    )
  end

  defp maybe_service(query, nil), do: query
  defp maybe_service(query, uuid), do: from(e in query, where: e.service_uuid == ^uuid)

  defp maybe_until(query, nil), do: query
  defp maybe_until(query, until), do: from(e in query, where: e.starts_at < ^until)

  defp maybe_services(query, nil), do: query

  defp maybe_services(query, uuids) when is_list(uuids),
    do: from(e in query, where: e.service_uuid in ^uuids)

  defp maybe_status(query, nil), do: query
  defp maybe_status(query, status), do: from(e in query, where: e.status == ^status)

  defp maybe_upcoming(query, true, now) do
    now = now || DateTime.utc_now()
    from(e in query, where: e.ends_at > ^now)
  end

  defp maybe_upcoming(query, _upcoming, _now), do: query

  def get_event(uuid) when is_binary(uuid) do
    repo().get(Event, uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_event(_), do: nil

  @doc "A scheduled, public event of an active service; nil otherwise."
  def get_public_event(uuid) do
    with %Event{status: "scheduled", public: true} = event <- get_event(uuid),
         %Service{status: "active"} <- Services.get_service(event.service_uuid) do
      event
    else
      _ -> nil
    end
  end

  @doc "The host profile uuid an event shows: its own, else its service's."
  def host_profile_uuid(%Event{host_profile_uuid: uuid}, _service) when not is_nil(uuid),
    do: uuid

  def host_profile_uuid(%Event{}, %Service{host_profile_uuid: uuid}), do: uuid
  def host_profile_uuid(%Event{}, _service), do: nil

  @doc "Seats an event offers: its own capacity, else its service's."
  def capacity(%Event{capacity: capacity}, _service) when is_integer(capacity), do: capacity
  def capacity(%Event{}, %Service{} = service), do: Services.effective_seats(service)

  @doc "Seats left (never negative)."
  def seats_left(%Event{} = event, %Service{} = service) do
    max(capacity(event, service) - Bookings.event_seats_taken(event.uuid), 0)
  end

  # ── Mutations ────────────────────────────────────────────────────────

  def create_event(attrs, opts \\ []) do
    %Event{}
    |> Event.changeset(attrs)
    |> repo().insert()
    |> tap_log("bookings.event_created", opts)
  end

  @doc """
  Updates an event. Judged under the event's row lock against the seats
  already taken: an event with active bookings cannot move to another
  service, and its capacity cannot drop below those seats. A status change
  to `"cancelled"` goes through `cancel_event/2`, so its bookings are
  cancelled too.
  """
  def update_event(%Event{} = event, attrs, opts \\ []) do
    changeset = Event.changeset(event, attrs)

    case Ecto.Changeset.get_change(changeset, :status) do
      "cancelled" ->
        with {:ok, updated} <- locked_update(Ecto.Changeset.delete_change(changeset, :status)) do
          tap_log({:ok, updated}, "bookings.event_updated", opts)
          cancel_event(updated, opts)
        end

      _ ->
        changeset |> locked_update() |> tap_log("bookings.event_updated", opts)
    end
  end

  defp locked_update(%Ecto.Changeset{data: %Event{uuid: uuid}} = changeset) do
    repo().transaction(fn ->
      repo().one(from(e in Event, where: e.uuid == ^uuid, lock: "FOR UPDATE"))
      taken = Bookings.event_seats_taken(uuid)

      case changeset |> check_taken(taken) |> repo().update() do
        {:ok, event} -> event
        {:error, cs} -> repo().rollback(cs)
      end
    end)
  end

  defp check_taken(changeset, 0), do: changeset

  defp check_taken(changeset, taken) do
    changeset
    |> then(fn cs ->
      if Ecto.Changeset.get_change(cs, :service_uuid),
        do:
          Ecto.Changeset.add_error(
            cs,
            :service_uuid,
            "cannot change while the event has bookings"
          ),
        else: cs
    end)
    |> then(fn cs ->
      case Ecto.Changeset.get_change(cs, :capacity) do
        capacity when is_integer(capacity) and capacity < taken ->
          Ecto.Changeset.add_error(cs, :capacity, "is below the %{count} seats already booked",
            count: taken
          )

        _ ->
          cs
      end
    end)
  end

  @doc """
  Cancels an event and every active booking at it (the customers are
  emailed unless `notify: false`). Returns `{:ok, event}`.
  """
  def cancel_event(%Event{} = event, opts \\ []) do
    with {:ok, cancelled} <-
           event |> Ecto.Changeset.change(status: "cancelled") |> repo().update() do
      from(b in Booking,
        where: b.event_uuid == ^event.uuid and b.status in ["pending", "confirmed"]
      )
      |> repo().all()
      |> Enum.each(
        &Bookings.cancel_booking(&1, Keyword.put_new(opts, :reason, "event cancelled"))
      )

      tap_log({:ok, cancelled}, "bookings.event_cancelled", opts)
    end
  end

  @doc "Deletes an event; its bookings stay (their `event_uuid` is cleared)."
  def delete_event(%Event{} = event, opts \\ []) do
    event
    |> repo().delete()
    |> tap_log("bookings.event_deleted", opts)
  end

  defp tap_log({:ok, event} = result, action, opts) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid],
      resource_type: "bookings_event",
      resource_uuid: event.uuid,
      metadata: %{"service_uuid" => event.service_uuid, "title" => event.title}
    )

    Services.broadcast_changed(event.service_uuid)
    Bookings.broadcast_changed(event.service_uuid)
    result
  end

  defp tap_log(result, _action, _opts), do: result

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
