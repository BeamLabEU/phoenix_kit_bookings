defmodule PhoenixKitBookings.Bookings do
  @moduledoc """
  Booking lifecycle: create (race-proof), confirm, cancel, and the queries
  that feed pickers and admin lists.

  ## Double-booking protection

  `Engine.validate_request/5` is pure and advisory. `create_booking/4`
  therefore re-runs it **inside a transaction that locks the service row**
  (`FOR UPDATE`, the `phoenix_kit_calendar` `Participants.lock_event/1`
  precedent): concurrent requests for the same service serialize, each
  re-reads the active bookings and re-validates against them, so the last
  seat can only be taken once. Cancelled rows stop counting immediately.

  ## Lifecycle

  `pending` (services with `require_approval` — RSVP-style) → `confirmed`
  → `cancelled`. Pending bookings HOLD capacity — an approval queue must
  not oversell; declining frees the seat.

  ## Live updates

  Every mutation broadcasts `{:bookings_changed, service_uuid}` on both
  `service_topic(service_uuid)` (public pickers refresh their slots) and
  `admin_topic/0` (admin lists refresh). Minimal payload, no PII.
  """

  import Ecto.Query

  alias PhoenixKitBookings.{Activity, Engine}
  alias PhoenixKitBookings.Schemas.{Booking, Service}

  @admin_topic "phoenix_kit_bookings:bookings"

  def admin_topic, do: @admin_topic

  @doc "Per-service PubSub topic — public pickers subscribe to exactly one."
  def service_topic(service_uuid), do: "phoenix_kit_bookings:service:#{service_uuid}"

  # ── Queries ──────────────────────────────────────────────────────────

  @doc """
  Lists bookings for the admin. Options: `:service_uuid`, `:status`,
  `:upcoming` (from today, site frame), `:limit` (default 200, newest
  window first).
  """
  def list_bookings(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(b in Booking,
      order_by: [asc_nulls_last: b.starts_at, asc_nulls_last: b.starts_on, desc: b.inserted_at],
      limit: ^limit
    )
    |> maybe_filter_service(opts[:service_uuid])
    |> maybe_filter_services(opts[:service_uuids])
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_upcoming(opts[:upcoming])
    |> repo().all()
  end

  defp maybe_filter_service(query, nil), do: query
  defp maybe_filter_service(query, uuid), do: from(b in query, where: b.service_uuid == ^uuid)

  defp maybe_filter_services(query, nil), do: query

  defp maybe_filter_services(query, uuids) when is_list(uuids),
    do: from(b in query, where: b.service_uuid in ^uuids)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: from(b in query, where: b.status == ^status)

  defp maybe_filter_upcoming(query, true) do
    today = Engine.today()
    now = DateTime.utc_now()

    from(b in query, where: b.ends_at > ^now or b.ends_on > ^today)
  end

  defp maybe_filter_upcoming(query, _), do: query

  @doc "Fetches a booking by UUID; nil on miss or forged id."
  def get_booking(uuid) do
    repo().get(Booking, uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Active (pending + confirmed) bookings of a service that overlap the
  given window — the engine's conflict input. `window` is
  `{from_utc, until_utc}` (DateTime) or `{:dates, from, until}` (Date),
  both exclusive-end.
  """
  def list_active_overlapping(service_uuid, {%DateTime{} = from, %DateTime{} = until}) do
    from(b in Booking,
      where: b.service_uuid == ^service_uuid,
      where: b.status in ["pending", "confirmed"],
      where: b.starts_at < ^until and b.ends_at > ^from
    )
    |> repo().all()
  end

  def list_active_overlapping(service_uuid, {:dates, %Date{} = from, %Date{} = until}) do
    from(b in Booking,
      where: b.service_uuid == ^service_uuid,
      where: b.status in ["pending", "confirmed"],
      where: b.starts_on < ^until and b.ends_on > ^from
    )
    |> repo().all()
  end

  @doc """
  Booking counts per status — powers the admin filter tabs.
  `opts[:service_uuids]` restricts to visible services (own-only admins).
  """
  def count_by_status(opts \\ []) do
    from(b in Booking, group_by: b.status, select: {b.status, count(b.uuid)})
    |> maybe_filter_services(opts[:service_uuids])
    |> repo().all()
    |> Map.new()
  end

  # ── Create ───────────────────────────────────────────────────────────

  @doc """
  Creates a booking of `service` for the validated `range`.

  `range`: `{starts_at_utc, ends_at_utc}` or `{:dates, starts_on, ends_on}`
  — must match the service's `time_unit` (the engine rejects a mismatch).

  `customer_attrs`: name / email / phone / notes (the only cast fields).

  Options: `:user_uuid` (the authenticated booker — REQUIRED when the
  service's `signup_policy` is `"login_required"`), `:source`
  (`"public"` default | `"admin"`), `:actor_uuid` (admin creating on
  behalf), `:now` (test injection).

  Returns `{:ok, booking}`, `{:error, %Ecto.Changeset{}}` (customer-field
  errors) or `{:error, reason_atom, message}` (engine rejection,
  `:login_required`, `:service_unavailable`).
  """
  def create_booking(%Service{} = service, range, customer_attrs, opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid)
    source = Keyword.get(opts, :source, "public")

    with :ok <- policy_gate(service, user_uuid, source),
         {:ok, changeset} <- build_changeset(service, range, customer_attrs, user_uuid, source) do
      insert_locked(service, range, changeset, opts)
    end
  end

  defp policy_gate(service, user_uuid, source) do
    cond do
      service.status != "active" and source != "admin" ->
        {:error, :service_unavailable, "This service is not currently bookable"}

      service.signup_policy == "login_required" and is_nil(user_uuid) and source != "admin" ->
        {:error, :login_required, "Please log in to book this service"}

      true ->
        :ok
    end
  end

  defp build_changeset(service, range, customer_attrs, user_uuid, source) do
    status = if service.require_approval and source != "admin", do: "pending", else: "confirmed"

    changeset =
      %Booking{}
      |> Booking.customer_changeset(customer_attrs)
      |> Booking.stamp_changeset(service.uuid, range, [
        {:status, status},
        {:source, source},
        {:user_uuid, user_uuid}
      ])

    if changeset.valid? do
      {:ok, changeset}
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp insert_locked(service, range, changeset, opts) do
    result =
      repo().transaction(fn ->
        # Serialize concurrent creates per service; the fresh reload under
        # the lock is what makes the capacity check race-proof.
        locked_service =
          repo().one!(from(s in Service, where: s.uuid == ^service.uuid, lock: "FOR UPDATE"))

        rules = PhoenixKitBookings.Services.list_rules(locked_service.uuid)

        active =
          list_active_overlapping(locked_service.uuid, conflict_window(locked_service, range))

        locked_service
        |> Engine.validate_request(rules, range, active, Keyword.take(opts, [:now, :today]))
        |> insert_validated(changeset)
      end)

    case result do
      {:ok, booking} ->
        log_and_broadcast(booking, "bookings.booking_created", opts)
        {:ok, booking}

      {:error, {:changeset, cs}} ->
        {:error, cs}

      {:error, {:rejected, reason, message}} ->
        {:error, reason, message}
    end
  end

  # Runs inside the locked transaction — rollback carries the outcome out.
  defp insert_validated(:ok, changeset) do
    case repo().insert(changeset) do
      {:ok, booking} -> booking
      {:error, cs} -> repo().rollback({:changeset, cs})
    end
  end

  defp insert_validated({:error, reason, message}, _changeset) do
    repo().rollback({:rejected, reason, message})
  end

  # The window of existing bookings the validator needs. Each side pads by
  # BOTH buffers: the request expands by its own buffer on that side AND a
  # neighboring booking expands toward the request by the opposite buffer
  # (`Engine.bookings_to_events/2` pre-expands events), so a booking just
  # outside the raw range can still conflict.
  defp conflict_window(service, {%DateTime{} = starts_at, %DateTime{} = ends_at}) do
    pad = (service.buffer_before + service.buffer_after) * 60

    {DateTime.add(starts_at, -pad, :second), DateTime.add(ends_at, pad, :second)}
  end

  defp conflict_window(_service, {:dates, starts_on, ends_on}), do: {:dates, starts_on, ends_on}

  # ── Lifecycle ────────────────────────────────────────────────────────

  @doc "Approves a pending booking (capacity was already held)."
  def confirm_booking(%Booking{status: "pending"} = booking, opts \\ []) do
    booking
    |> Booking.status_changeset("confirmed")
    |> repo().update()
    |> tap_lifecycle("bookings.booking_confirmed", opts)
  end

  @doc "Cancels a pending or confirmed booking; frees capacity immediately."
  def cancel_booking(booking, opts \\ [])

  def cancel_booking(%Booking{status: status} = booking, opts)
      when status in ["pending", "confirmed"] do
    booking
    |> Booking.status_changeset("cancelled", reason: opts[:reason])
    |> repo().update()
    |> tap_lifecycle("bookings.booking_cancelled", opts)
  end

  def cancel_booking(%Booking{} = _booking, _opts),
    do: {:error, :not_cancellable, "This booking is already cancelled"}

  # ── Guest manage tokens ──────────────────────────────────────────────

  @token_salt "phoenix_kit_bookings.manage"
  # 90 days — long enough to outlive any realistic booking horizon window
  # a cancel link is mailed for.
  @token_max_age 90 * 24 * 3600

  @doc "Signed token a guest uses to view/cancel their booking without an account."
  def manage_token(%Booking{uuid: uuid}) do
    Phoenix.Token.sign(token_endpoint(), @token_salt, uuid)
  end

  @doc "Resolves a manage token back to its booking; nil when invalid/expired."
  def booking_from_token(token) when is_binary(token) do
    case Phoenix.Token.verify(token_endpoint(), @token_salt, token, max_age: @token_max_age) do
      {:ok, uuid} -> get_booking(uuid)
      {:error, _} -> nil
    end
  end

  def booking_from_token(_), do: nil

  # Explicit `config :phoenix_kit, endpoint:` wins (tests set it); a host
  # app is discovered via core's :parent_module resolution — core's own
  # PhoenixKitWeb.Endpoint is compiled but NOT running in a host, so
  # falling back to it would crash Phoenix.Token on the ETS lookup.
  defp token_endpoint do
    case PhoenixKit.Config.get(:endpoint) do
      {:ok, endpoint} ->
        endpoint

      _ ->
        case PhoenixKit.Config.get_parent_endpoint() do
          {:ok, endpoint} -> endpoint
          :error -> PhoenixKitWeb.Endpoint
        end
    end
  end

  # ── Plumbing ─────────────────────────────────────────────────────────

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp tap_lifecycle({:ok, booking} = result, action, opts) do
    log_and_broadcast(booking, action, opts)
    result
  end

  defp tap_lifecycle(result, _action, _opts), do: result

  defp log_and_broadcast(%Booking{} = booking, action, opts) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid] || booking.user_uuid,
      resource_type: "booking",
      resource_uuid: booking.uuid,
      metadata: %{"service_uuid" => booking.service_uuid, "status" => booking.status}
    )

    broadcast_changed(booking.service_uuid)
  end

  defp broadcast_changed(service_uuid) do
    case PhoenixKit.Config.pubsub_server() do
      nil ->
        :ok

      pubsub ->
        message = {:bookings_changed, service_uuid}
        Phoenix.PubSub.broadcast(pubsub, service_topic(service_uuid), message)
        Phoenix.PubSub.broadcast(pubsub, @admin_topic, message)
    end
  rescue
    _ -> :ok
  end
end
