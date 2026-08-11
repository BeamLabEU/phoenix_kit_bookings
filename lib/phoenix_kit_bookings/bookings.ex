defmodule PhoenixKitBookings.Bookings do
  @moduledoc """
  Booking lifecycle: create (race-proof), confirm, cancel — plus holds,
  waitlist, unit auto-assignment, pricing, and the queries that feed
  pickers and admin lists.

  ## Double-booking protection

  `Engine.validate_request/5` is pure and advisory. `create_booking/4`
  therefore re-runs it **inside a transaction that locks the service row**
  (`FOR UPDATE`): concurrent requests serialize, each re-reads the active
  occupancy (bookings + unexpired holds) and re-validates, so the last
  seat can only be taken once. When the service has a provider, ALL of
  that provider's services are locked in uuid order (deadlock-safe), and
  the provider's other bookings block the request absolutely.

  ## Lifecycle

  `pending` (services with `require_approval` — RSVP-style) → `confirmed`
  → `cancelled`. Pending bookings HOLD capacity. A cancellation frees
  capacity immediately, emails the customer, and notifies open waitlist
  entries for the freed dates (notify-all-first-to-book).

  ## Live updates

  Every mutation broadcasts `{:bookings_changed, service_uuid}` on both
  `service_topic(service_uuid)` and `admin_topic/0`. Minimal payload.
  """

  import Ecto.Query

  alias PhoenixKitBookings.{Activity, Engine, Notifier, Pricing, Services}
  alias PhoenixKitBookings.Schemas.{Booking, Hold, Service, Unit, WaitlistEntry}
  alias PhoenixKitBookings.Workers.ReminderWorker

  @admin_topic "phoenix_kit_bookings:bookings"

  # How long a public visitor's picked slot stays reserved while they
  # fill in the details form.
  @hold_ttl_seconds 5 * 60

  def admin_topic, do: @admin_topic

  @doc "Per-service PubSub topic — public pickers subscribe to exactly one."
  def service_topic(service_uuid), do: "phoenix_kit_bookings:service:#{service_uuid}"

  # ── Queries ──────────────────────────────────────────────────────────

  @doc """
  Lists bookings for the admin. Options: `:service_uuid`,
  `:service_uuids`, `:status`, `:upcoming` (from today, site frame),
  `:limit` (default 200).
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
  given window. `window` is `{from_utc, until_utc}` or
  `{:dates, from, until}`, both exclusive-end.
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
  The full occupancy the validator sees: active bookings PLUS unexpired
  holds (mapped to pseudo-bookings), minus `opts[:exclude_hold]` (the
  caller's own hold). This is what pickers and the locked create both
  consume, so a held slot greys out everywhere.
  """
  def list_occupancy(service_uuid, window, opts \\ []) do
    list_active_overlapping(service_uuid, window) ++
      (service_uuid
       |> list_active_holds_overlapping(window, opts[:exclude_hold])
       |> Enum.map(&hold_to_pseudo_booking/1))
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

  Options: `:user_uuid` (REQUIRED when `signup_policy` is
  `"login_required"`), `:source` (`"public"` default | `"admin"`),
  `:actor_uuid`, `:hold_uuid` (the caller's own hold — excluded from the
  capacity check and consumed on success), `:now`/`:today` (test
  injection).

  On success the booking carries the computed `total_price`/`currency`
  (priced services) and an auto-assigned `unit_uuid` (unit-tracked
  services); the confirmation email + reminder job fire best-effort.

  Returns `{:ok, booking}`, `{:error, %Ecto.Changeset{}}` or
  `{:error, reason_atom, message}`.
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
        locked_service = lock_service_tree(service)
        prune_expired_holds(locked_service.uuid)

        units = Services.list_active_units(locked_service.uuid)
        effective = effective_service(locked_service, units)
        rules = Services.list_rules(locked_service.uuid)
        window = conflict_window(effective, range)

        occupancy =
          list_occupancy(locked_service.uuid, window, exclude_hold: opts[:hold_uuid])

        extra_events = provider_blocking_events(effective, range)

        effective
        |> Engine.validate_request(
          rules,
          range,
          occupancy,
          Keyword.take(opts, [:now, :today]) ++ [extra_events: extra_events]
        )
        |> insert_validated(changeset, effective, units, range, opts)
      end)

    case result do
      {:ok, booking} ->
        after_create(booking, service, opts)
        {:ok, booking}

      {:error, {:changeset, cs}} ->
        {:error, cs}

      {:error, {:rejected, reason, message}} ->
        {:error, reason, message}
    end
  end

  # Locks the service row — and, when a provider is attached, ALL the
  # provider's service rows in uuid order so cross-service provider
  # conflicts serialize without deadlocks.
  defp lock_service_tree(%Service{provider_uuid: nil} = service) do
    repo().one!(from(s in Service, where: s.uuid == ^service.uuid, lock: "FOR UPDATE"))
  end

  defp lock_service_tree(%Service{provider_uuid: provider_uuid} = service) do
    from(s in Service,
      where: s.provider_uuid == ^provider_uuid or s.uuid == ^service.uuid,
      order_by: [asc: s.uuid],
      lock: "FOR UPDATE"
    )
    |> repo().all()
    |> Enum.find(&(&1.uuid == service.uuid))
  end

  # Unit-tracked services derive capacity from their active unit count.
  defp effective_service(service, []), do: service
  defp effective_service(service, units), do: %{service | seats: length(units)}

  # Runs inside the locked transaction — rollback carries the outcome out.
  defp insert_validated(:ok, changeset, effective, units, range, opts) do
    changeset =
      changeset
      |> Ecto.Changeset.change(
        unit_uuid: pick_unit(units, effective, range),
        total_price: Pricing.total(effective, range),
        currency: if(effective.price, do: effective.currency)
      )

    case repo().insert(changeset) do
      {:ok, booking} ->
        consume_hold(opts[:hold_uuid])
        booking

      {:error, cs} ->
        repo().rollback({:changeset, cs})
    end
  end

  defp insert_validated({:error, reason, message}, _changeset, _eff, _units, _range, _opts) do
    repo().rollback({:rejected, reason, message})
  end

  # Least-loaded assignment: the first (by name) active unit not occupied
  # by an overlapping active booking. Legacy bookings without a unit
  # consume capacity but no unit — the capacity check has already
  # guaranteed the count fits.
  defp pick_unit([], _service, _range), do: nil

  defp pick_unit(units, service, range) do
    occupied =
      service.uuid
      |> list_active_overlapping(raw_window(range))
      |> Enum.map(& &1.unit_uuid)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.find_value(units, fn %Unit{} = unit ->
      if MapSet.member?(occupied, unit.uuid), do: nil, else: unit.uuid
    end)
  end

  defp raw_window({%DateTime{} = from, %DateTime{} = until}), do: {from, until}
  defp raw_window({:dates, from, until}), do: {:dates, from, until}

  # Provider-attached minute services: the provider's OTHER bookings block
  # this request absolutely (a person can't be in two places).
  defp provider_blocking_events(%Service{provider_uuid: nil}, _range), do: []
  defp provider_blocking_events(%Service{time_unit: unit}, _range) when unit != "minutes", do: []

  defp provider_blocking_events(%Service{} = service, {%DateTime{} = from, %DateTime{} = until}) do
    sibling_uuids =
      from(s in Service,
        where: s.provider_uuid == ^service.provider_uuid and s.uuid != ^service.uuid,
        where: s.status != "trashed",
        select: s.uuid
      )
      |> repo().all()

    case sibling_uuids do
      [] ->
        []

      uuids ->
        from(b in Booking,
          where: b.service_uuid in ^uuids,
          where: b.status in ["pending", "confirmed"],
          where: b.starts_at < ^until and b.ends_at > ^from
        )
        |> repo().all()
        |> Engine.blocking_events()
    end
  end

  defp provider_blocking_events(_service, _range), do: []

  # The window of existing occupancy the validator needs. Each side pads
  # by BOTH buffers: the request expands by its own buffer on that side
  # AND a neighboring booking expands toward the request by the opposite
  # buffer (`Engine.bookings_to_events/2` pre-expands events).
  defp conflict_window(service, {%DateTime{} = starts_at, %DateTime{} = ends_at}) do
    pad = (service.buffer_before + service.buffer_after) * 60

    {DateTime.add(starts_at, -pad, :second), DateTime.add(ends_at, pad, :second)}
  end

  defp conflict_window(_service, {:dates, starts_on, ends_on}), do: {:dates, starts_on, ends_on}

  defp after_create(booking, service, opts) do
    log_and_broadcast(booking, "bookings.booking_created", opts)
    Notifier.booking_created(booking, service)
    ReminderWorker.schedule(booking, service)
  end

  # ── Lifecycle ────────────────────────────────────────────────────────

  @doc "Approves a pending booking (capacity was already held)."
  def confirm_booking(%Booking{status: "pending"} = booking, opts \\ []) do
    booking
    |> Booking.status_changeset("confirmed")
    |> repo().update()
    |> tap_lifecycle("bookings.booking_confirmed", opts, &Notifier.booking_confirmed/2)
  end

  @doc "Cancels a pending or confirmed booking; frees capacity immediately."
  def cancel_booking(booking, opts \\ [])

  def cancel_booking(%Booking{status: status} = booking, opts)
      when status in ["pending", "confirmed"] do
    booking
    |> Booking.status_changeset("cancelled", reason: opts[:reason])
    |> repo().update()
    |> tap_lifecycle("bookings.booking_cancelled", opts, &Notifier.booking_cancelled/2)
    |> tap_waitlist()
  end

  def cancel_booking(%Booking{} = _booking, _opts),
    do: {:error, :not_cancellable, "This booking is already cancelled"}

  @doc """
  Whether a CUSTOMER may still self-cancel: active, upcoming, and outside
  the service's `cancel_notice` window (admins cancel unrestricted).
  """
  def cancellable_by_customer?(%Booking{status: status}, _service)
      when status not in ["pending", "confirmed"],
      do: false

  def cancellable_by_customer?(%Booking{starts_at: %DateTime{} = starts_at}, %Service{} = service) do
    cutoff = DateTime.add(starts_at, -service.cancel_notice * 60, :second)
    DateTime.compare(DateTime.utc_now(), cutoff) == :lt
  end

  def cancellable_by_customer?(%Booking{starts_on: %Date{} = starts_on}, %Service{} = service) do
    days_notice = div(service.cancel_notice + 1439, 1440)
    Date.compare(Engine.today(), Date.add(starts_on, -days_notice)) == :lt
  end

  def cancellable_by_customer?(_booking, _service), do: false

  # ── Holds ────────────────────────────────────────────────────────────

  @doc """
  Reserves the picked range for #{div(@hold_ttl_seconds, 60)} minutes
  while the visitor fills the details form. Advisory (created after the
  advisory validation passed) — the locked create is still the authority.
  """
  def create_hold(%Service{} = service, range, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @hold_ttl_seconds)

    attrs =
      case range do
        {%DateTime{} = starts_at, %DateTime{} = ends_at} ->
          %{
            starts_at: DateTime.truncate(starts_at, :second),
            ends_at: DateTime.truncate(ends_at, :second)
          }

        {:dates, starts_on, ends_on} ->
          %{starts_on: starts_on, ends_on: ends_on}
      end

    %Hold{service_uuid: service.uuid}
    |> Ecto.Changeset.change(
      Map.put(
        attrs,
        :expires_at,
        DateTime.add(DateTime.utc_now(), ttl, :second) |> DateTime.truncate(:second)
      )
    )
    |> repo().insert()
    |> tap_broadcast_hold(service.uuid)
  end

  @doc "Releases a hold (back button, LiveView terminate). Idempotent."
  def release_hold(nil), do: :ok

  def release_hold(hold_uuid) do
    {_count, _} = from(h in Hold, where: h.uuid == ^hold_uuid) |> repo().delete_all()
    :ok
  rescue
    Ecto.Query.CastError -> :ok
  end

  defp consume_hold(nil), do: :ok

  defp consume_hold(hold_uuid) do
    from(h in Hold, where: h.uuid == ^hold_uuid) |> repo().delete_all()
    :ok
  end

  defp list_active_holds_overlapping(service_uuid, window, exclude_uuid) do
    now = DateTime.utc_now()

    base =
      from(h in Hold,
        where: h.service_uuid == ^service_uuid,
        where: h.expires_at > ^now
      )

    base =
      case window do
        {%DateTime{} = from, %DateTime{} = until} ->
          from(h in base, where: h.starts_at < ^until and h.ends_at > ^from)

        {:dates, %Date{} = from, %Date{} = until} ->
          from(h in base, where: h.starts_on < ^until and h.ends_on > ^from)
      end

    base =
      case exclude_uuid do
        nil -> base
        uuid -> from(h in base, where: h.uuid != ^uuid)
      end

    repo().all(base)
  end

  defp hold_to_pseudo_booking(%Hold{} = hold) do
    %Booking{
      uuid: hold.uuid,
      service_uuid: hold.service_uuid,
      status: "confirmed",
      starts_at: hold.starts_at,
      ends_at: hold.ends_at,
      starts_on: hold.starts_on,
      ends_on: hold.ends_on
    }
  end

  defp prune_expired_holds(service_uuid) do
    now = DateTime.utc_now()

    from(h in Hold, where: h.service_uuid == ^service_uuid and h.expires_at <= ^now)
    |> repo().delete_all()
  end

  # ── Waitlist ─────────────────────────────────────────────────────────

  @doc """
  Joins the waitlist for a date. One open entry per email+date+service —
  repeat joins are collapsed.
  """
  def join_waitlist(%Service{} = service, attrs) do
    changeset = WaitlistEntry.changeset(%WaitlistEntry{}, attrs)

    with true <- changeset.valid?,
         email = Ecto.Changeset.get_field(changeset, :customer_email),
         date = Ecto.Changeset.get_field(changeset, :date),
         nil <- open_waitlist_entry(service.uuid, email, date) do
      changeset
      |> Ecto.Changeset.put_change(:service_uuid, service.uuid)
      |> repo().insert()
    else
      false -> {:error, %{changeset | action: :insert}}
      %WaitlistEntry{} = existing -> {:ok, existing}
    end
  end

  defp open_waitlist_entry(service_uuid, email, date) do
    repo().get_by(WaitlistEntry,
      service_uuid: service_uuid,
      customer_email: email,
      date: date,
      status: "open"
    )
  end

  @doc "Open-entry counts per service — admin visibility."
  def waitlist_counts do
    from(w in WaitlistEntry,
      where: w.status == "open",
      group_by: w.service_uuid,
      select: {w.service_uuid, count(w.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Waitlist entries of a service, open first, newest first."
  def list_waitlist(service_uuid) do
    from(w in WaitlistEntry,
      where: w.service_uuid == ^service_uuid,
      order_by: [asc: w.status, desc: w.inserted_at]
    )
    |> repo().all()
  end

  # A cancellation freed the booking's dates: notify every open entry for
  # those dates (notify-all-first-to-book) and flip them to notified.
  defp tap_waitlist({:ok, %Booking{} = booking} = result) do
    case Services.get_service(booking.service_uuid) do
      nil ->
        result

      service ->
        Enum.each(freed_dates(booking), &notify_waitlist_date(service, &1))
        result
    end
  end

  defp tap_waitlist(result), do: result

  defp notify_waitlist_date(service, date) do
    from(w in WaitlistEntry,
      where: w.service_uuid == ^service.uuid,
      where: w.date == ^date,
      where: w.status == "open"
    )
    |> repo().all()
    |> Enum.each(fn entry ->
      Notifier.waitlist_opening(entry, service, date)
      entry |> Ecto.Changeset.change(status: "notified") |> repo().update()
    end)
  end

  defp freed_dates(%Booking{starts_at: %DateTime{} = starts_at}) do
    [starts_at |> Engine.utc_to_frame() |> DateTime.to_date()]
  end

  defp freed_dates(%Booking{starts_on: %Date{} = starts_on, ends_on: ends_on}) do
    Date.range(starts_on, Date.add(ends_on, -1)) |> Enum.to_list()
  end

  defp freed_dates(_), do: []

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

  defp tap_lifecycle({:ok, booking} = result, action, opts, notify_fun) do
    log_and_broadcast(booking, action, opts)

    case Services.get_service(booking.service_uuid) do
      nil -> :ok
      service -> notify_fun.(booking, service)
    end

    result
  end

  defp tap_lifecycle(result, _action, _opts, _notify), do: result

  defp log_and_broadcast(%Booking{} = booking, action, opts) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid] || booking.user_uuid,
      resource_type: "booking",
      resource_uuid: booking.uuid,
      metadata: %{"service_uuid" => booking.service_uuid, "status" => booking.status}
    )

    broadcast_changed(booking.service_uuid)
  end

  defp tap_broadcast_hold({:ok, _hold} = result, service_uuid) do
    broadcast_changed(service_uuid)
    result
  end

  defp tap_broadcast_hold(result, _service_uuid), do: result

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
