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

  alias PhoenixKitBookings.{Activity, Bookings, Notifier, Services}
  alias PhoenixKitBookings.Schemas.{Booking, Event, Service}
  alias PhoenixKitBookings.Workers.ReminderWorker

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
  Updates an event. The changes are judged on the row under its lock (not
  on the caller's struct, which may be stale) against the seats already
  taken:

  - its capacity — its own, or the service's when set to blank — cannot drop
    below those seats;
  - new times or another service MOVE its active bookings in the same
    transaction (a unit of the old service is released; the total the
    customer agreed to is kept), unless the service is full at the new time
    (`Bookings.service_full_for_event?/3`) or is a day/night service;
    each moved customer is emailed the new times with an updated `.ics`
    and their reminder is rescheduled (both skipped with `notify: false`);
  - a status change to `"cancelled"` is committed in the same locked write,
    so no sign-up slips in, and then cancels the event's bookings like
    `cancel_event/2`.

  The service rows are locked before the event row, the order a sign-up
  takes them in. Returns `{:ok, event}`, `{:error, changeset}`, or
  `{:error, :not_found | :conflict}` (the event is gone, or moved by
  someone else meanwhile).
  """
  def update_event(%Event{uuid: uuid}, attrs, opts \\ []) do
    uuid
    |> locked_update(attrs)
    |> after_update(opts)
  end

  defp locked_update(uuid, attrs) do
    repo().transaction(fn ->
      current = get_event(uuid) || repo().rollback(:not_found)
      lock_services([current.service_uuid, attrs["service_uuid"] || attrs[:service_uuid]])
      locked = lock_event(uuid) || repo().rollback(:not_found)

      if locked.service_uuid != current.service_uuid, do: repo().rollback(:conflict)

      changeset = locked |> Event.changeset(attrs) |> check_taken(locked)

      case repo().update(changeset) do
        {:ok, event} ->
          moved = move_bookings(locked, event)
          {event, locked.status != "cancelled" and event.status == "cancelled", moved}

        {:error, cs} ->
          repo().rollback(cs)
      end
    end)
  end

  defp lock_services(uuids) do
    uuids =
      uuids
      |> Enum.flat_map(fn uuid ->
        case Ecto.UUID.cast(uuid || "") do
          {:ok, valid} -> [valid]
          :error -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    from(s in Service, where: s.uuid in ^uuids, order_by: s.uuid, lock: "FOR UPDATE")
    |> repo().all()
  end

  defp after_update({:ok, {event, true, moved}}, opts) do
    notify_moved(moved, opts)
    cancel_bookings(event, opts)
    tap_log({:ok, event}, "bookings.event_cancelled", opts)
  end

  # Saving a cancelled event again also finishes a sweep an earlier
  # cancellation did not complete (cancel_bookings/2 is idempotent).
  defp after_update({:ok, {%Event{status: "cancelled"} = event, false, moved}}, opts) do
    notify_moved(moved, opts)
    cancel_bookings(event, opts)
    tap_log({:ok, event}, "bookings.event_updated", opts)
  end

  defp after_update({:ok, {event, false, moved}}, opts) do
    notify_moved(moved, opts)
    tap_log({:ok, event}, "bookings.event_updated", opts)
  end

  defp after_update({:error, _} = error, _opts), do: error

  defp lock_event(uuid),
    do: repo().one(from(e in Event, where: e.uuid == ^uuid, lock: "FOR UPDATE"))

  defp check_taken(changeset, %Event{uuid: uuid} = locked) do
    case Bookings.event_seats_taken(uuid) do
      0 -> changeset
      taken -> changeset |> refuse_capacity(locked, taken) |> refuse_full_service(taken)
    end
  end

  defp refuse_capacity(changeset, locked, taken) do
    if Ecto.Changeset.changed?(changeset, :capacity) or
         Ecto.Changeset.changed?(changeset, :service_uuid) do
      new = Ecto.Changeset.get_field(changeset, :capacity)
      service_uuid = Ecto.Changeset.get_field(changeset, :service_uuid) || locked.service_uuid
      offered = new || service_seats(service_uuid)

      if offered < taken,
        do:
          Ecto.Changeset.add_error(
            changeset,
            :capacity,
            "is below the %{count} seats already booked",
            count: taken
          ),
        else: changeset
    else
      changeset
    end
  end

  defp service_seats(uuid) do
    case Services.get_service(uuid) do
      nil -> 0
      service -> Services.effective_seats(service)
    end
  end

  # Bookings that move with the event must fit where it goes.
  defp refuse_full_service(%Ecto.Changeset{valid?: false} = changeset, _taken), do: changeset

  defp refuse_full_service(changeset, taken) do
    if moves?(changeset) do
      event = Ecto.Changeset.apply_changes(changeset)

      case Services.get_service(event.service_uuid) do
        nil -> changeset
        service -> refuse_destination(changeset, service, event, taken)
      end
    else
      changeset
    end
  end

  # Timed bookings cannot move onto a day/night service (its capacity reads
  # dates), and must fit beside its other bookings.
  defp refuse_destination(changeset, %Service{time_unit: unit}, _event, _taken)
       when unit != "minutes",
       do:
         Ecto.Changeset.add_error(
           changeset,
           :service_uuid,
           "must be a minute-based service while the event has bookings"
         )

  defp refuse_destination(changeset, service, event, taken) do
    if Bookings.service_full_for_event?(service, event, taken),
      do:
        Ecto.Changeset.add_error(
          changeset,
          :starts_at,
          "the service is fully booked at the new time"
        ),
      else: changeset
  end

  defp moves?(changeset),
    do: Enum.any?([:service_uuid, :starts_at, :ends_at], &Ecto.Changeset.changed?(changeset, &1))

  # The event's active bookings follow it; each comes back with what it was.
  defp move_bookings(%Event{} = before, %Event{} = now) do
    if before.starts_at == now.starts_at and before.ends_at == now.ends_at and
         before.service_uuid == now.service_uuid do
      []
    else
      rows =
        from(b in Booking,
          where: b.event_uuid == ^now.uuid and b.status in ["pending", "confirmed"]
        )
        |> repo().all()

      unit_reset = if before.service_uuid != now.service_uuid, do: [unit_uuid: nil], else: []
      stamp = DateTime.truncate(DateTime.utc_now(), :second)

      {_n, moved} =
        from(b in Booking, where: b.uuid in ^Enum.map(rows, & &1.uuid), select: b)
        |> repo().update_all(
          set:
            [
              starts_at: DateTime.truncate(now.starts_at, :second),
              ends_at: DateTime.truncate(now.ends_at, :second),
              service_uuid: now.service_uuid,
              updated_at: stamp
            ] ++ unit_reset
        )

      previous = Map.new(rows, &{&1.uuid, &1})
      Enum.map(moved, &{&1, Map.fetch!(previous, &1.uuid)})
    end
  end

  defp notify_moved([], _opts), do: :ok

  defp notify_moved([{first, previous} | _] = moved, opts) do
    service = Services.get_service(first.service_uuid)

    for {booking, before} <- moved do
      Activity.log("bookings.booking_rescheduled",
        actor_uuid: opts[:actor_uuid],
        resource_type: "booking",
        resource_uuid: booking.uuid,
        metadata: %{"service_uuid" => booking.service_uuid, "event_uuid" => booking.event_uuid}
      )

      if service && opts[:notify] != false do
        Notifier.booking_rescheduled(booking, service, before)
        ReminderWorker.schedule(booking, service)
      end
    end

    if previous.service_uuid != first.service_uuid,
      do: Bookings.broadcast_changed(previous.service_uuid)

    :ok
  end

  @doc """
  Cancels an event and every active booking at it (the customers are
  emailed unless `notify: false`). Returns `{:ok, event}`.
  """
  def cancel_event(%Event{} = event, opts \\ []) do
    with {:ok, cancelled} <-
           event |> Ecto.Changeset.change(status: "cancelled") |> repo().update() do
      cancel_bookings(cancelled, opts)
      tap_log({:ok, cancelled}, "bookings.event_cancelled", opts)
    end
  end

  # Only bookings made before the cancellation was stamped: if the event is
  # reinstated before this sweep runs, a sign-up taken since then stays.
  defp cancel_bookings(%Event{uuid: uuid, updated_at: cancelled_at}, opts) do
    from(b in Booking,
      where: b.event_uuid == ^uuid and b.status in ["pending", "confirmed"],
      where: b.inserted_at <= ^cancelled_at
    )
    |> repo().all()
    |> Enum.each(&Bookings.cancel_booking(&1, Keyword.put_new(opts, :reason, "event cancelled")))
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
