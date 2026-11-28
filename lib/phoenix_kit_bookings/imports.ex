defmodule PhoenixKitBookings.Imports do
  @moduledoc """
  Availability that comes from somewhere else — a firm's own booking
  calendar, an iCal feed, a channel manager — stored as rows the owner's own
  edits can always be told apart from.

  Imported rows carry `source: "import"` plus an `external_source` (which
  feed: `"ical"`, `"smartbron"`, …) and an `external_id` (the entry's id
  there). A sync names its `external_source` and hands over the FULL current
  list of that source's entries for the service:

  - an entry whose `external_id` exists is updated in place,
  - a new one is inserted,
  - a row of that source that is no longer in the list is removed,

  and nothing else is touched: not the owner's bookings or rules, not another
  source's rows. `(service_uuid, external_source, external_id)` is unique in
  both tables.

  Imported bookings are facts, not requests: they skip the engine's
  validation (an outside calendar may hold what this site's rules would
  refuse), send no email, schedule no reminder and need no customer. They
  count toward capacity like any booking, one seat each. Each sync runs in
  one transaction under the service row lock, so it cannot interleave with a
  booking being made.
  """

  import Ecto.Query

  alias PhoenixKitBookings.{Activity, Bookings, Services}
  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Booking, Service}

  @type booking_entry :: %{
          required(:external_id) => String.t(),
          required(:range) => {DateTime.t(), DateTime.t()} | {:dates, Date.t(), Date.t()},
          optional(:customer_name) => String.t() | nil,
          optional(:notes) => String.t() | nil,
          optional(:metadata) => map()
        }

  @doc """
  Replaces the imported bookings of `external_source` on `service` with
  `entries` (see `t:booking_entry/0`).

  Returns `{:ok, %{inserted: n, updated: n, deleted: n}}`, or
  `{:error, {external_id, changeset}}` for the first entry that does not fit
  (nothing is written then). Options: `:actor_uuid`, and `:fetched_at` (a
  `DateTime`: when the caller read the list from its source). With
  `:fetched_at`, a list read BEFORE the one last applied for this source is
  refused as `{:error, :stale_result}` and changes nothing — two syncs that
  overlap (a cron run and "Sync now") cannot let the older snapshot
  overwrite the newer. Syncs of one service are serialised by its row lock.
  """
  def sync_bookings(%Service{} = service, external_source, entries, opts \\ [])
      when is_binary(external_source) and is_list(entries) do
    sync(service, external_source, entries, opts, %{
      schema: Booking,
      kind: "bookings",
      action: "bookings.import_synced",
      build: fn existing, entry ->
        Booking.import_changeset(
          existing || %Booking{},
          service.uuid,
          entry.range,
          external_source,
          entry.external_id,
          Map.take(entry, [:customer_name, :customer_email, :notes, :metadata])
        )
      end,
      changed?: &booking_changed?/2
    })
  end

  @doc """
  Replaces the imported availability rules of `external_source` on
  `service` with `rules`: maps of the rule fields (`days_of_week` / `date`,
  `start_time` / `end_time`, `available`) plus `:external_id`. Same contract
  as `sync_bookings/4`.
  """
  def sync_rules(%Service{} = service, external_source, rules, opts \\ [])
      when is_binary(external_source) and is_list(rules) do
    sync(service, external_source, rules, opts, %{
      schema: AvailabilityRule,
      kind: "rules",
      action: "bookings.import_rules_synced",
      build: fn existing, entry ->
        AvailabilityRule.import_changeset(
          existing || %AvailabilityRule{},
          entry |> Map.delete(:external_id) |> stringify(),
          service.time_unit,
          service.uuid,
          external_source,
          entry.external_id
        )
      end,
      changed?: fn _existing, changeset -> changeset.changes != %{} end
    })
  end

  defp sync(service, external_source, entries, opts, spec) do
    entries = dedupe(entries)

    result =
      repo().transaction(fn ->
        locked = lock_service!(service)

        # The entries were shaped for the caller's struct (timed vs dated);
        # a service switched to another unit since then would take rows of
        # the wrong shape, so the sync stops and the next one maps afresh.
        if locked.time_unit != service.time_unit, do: repo().rollback(:service_changed)

        if Keyword.has_key?(opts, :expected_ical_url) and
             locked.ical_url != opts[:expected_ical_url],
           do: repo().rollback(:service_changed)

        claim_fetch!(locked, "#{external_source}/#{spec.kind}", opts[:fetched_at])

        existing =
          from(r in spec.schema,
            where: r.service_uuid == ^service.uuid,
            where: r.source == "import" and r.external_source == ^external_source
          )
          |> repo().all()
          |> Map.new(&{&1.external_id, &1})

        stats =
          Enum.reduce(
            entries,
            %{inserted: 0, updated: 0, deleted: 0},
            &write_entry(&1, &2, existing, spec)
          )

        keep = MapSet.new(entries, & &1.external_id)
        stale = for {id, row} <- existing, not MapSet.member?(keep, id), do: row.uuid

        {deleted, _} =
          case stale do
            [] -> {0, nil}
            uuids -> from(r in spec.schema, where: r.uuid in ^uuids) |> repo().delete_all()
          end

        %{stats | deleted: deleted}
      end)

    with {:ok, stats} <- result do
      Activity.log(spec.action,
        actor_uuid: opts[:actor_uuid],
        resource_type: "bookings_service",
        resource_uuid: service.uuid,
        metadata: %{
          "external_source" => external_source,
          "inserted" => stats.inserted,
          "updated" => stats.updated,
          "deleted" => stats.deleted
        }
      )

      Bookings.broadcast_changed(service.uuid)
      Services.broadcast_changed(service.uuid)
      {:ok, stats}
    end
  end

  defp write_entry(entry, stats, existing, spec) do
    current = Map.get(existing, entry.external_id)
    changeset = spec.build.(current, entry)

    cond do
      not changeset.valid? ->
        repo().rollback({entry.external_id, changeset})

      is_nil(current) ->
        insert!(changeset, entry)
        Map.update!(stats, :inserted, &(&1 + 1))

      spec.changed?.(current, changeset) ->
        update!(changeset, entry)
        Map.update!(stats, :updated, &(&1 + 1))

      true ->
        stats
    end
  end

  defp insert!(changeset, entry) do
    case repo().insert(changeset) do
      {:ok, row} -> row
      {:error, cs} -> repo().rollback({entry.external_id, cs})
    end
  end

  defp update!(changeset, entry) do
    case repo().update(changeset) do
      {:ok, row} -> row
      {:error, cs} -> repo().rollback({entry.external_id, cs})
    end
  end

  # `clear_range/1` puts every time field, so compare what really moved.
  defp booking_changed?(%Booking{} = current, changeset) do
    Enum.any?(changeset.changes, fn {field, value} -> Map.get(current, field) != value end)
  end

  # The last entry of an id wins, as a feed listing it twice would mean.
  defp dedupe(entries) do
    entries
    |> Enum.map(&Map.update!(&1, :external_id, fn id -> to_string(id) end))
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.external_id)
    |> Enum.reverse()
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # The newest applied read wins: an older one rolls back untouched; a newer
  # one is recorded in the service's settings under the lock.
  defp claim_fetch!(_locked, _key, nil), do: :ok

  defp claim_fetch!(%Service{} = locked, key, %DateTime{} = fetched_at) do
    applied = get_in(locked.settings || %{}, ["import_fetched_at", key])

    with iso when is_binary(iso) <- applied,
         {:ok, last, _} <- DateTime.from_iso8601(iso),
         :lt <- DateTime.compare(fetched_at, last) do
      repo().rollback(:stale_result)
    else
      _ ->
        settings = locked.settings || %{}

        marks =
          Map.put(settings["import_fetched_at"] || %{}, key, DateTime.to_iso8601(fetched_at))

        from(s in Service, where: s.uuid == ^locked.uuid)
        |> repo().update_all(set: [settings: Map.put(settings, "import_fetched_at", marks)])

        :ok
    end
  end

  defp lock_service!(service) do
    case repo().one(from(s in Service, where: s.uuid == ^service.uuid, lock: "FOR UPDATE")) do
      nil -> repo().rollback(:service_not_found)
      locked -> locked
    end
  end

  @doc "Imported bookings of a service (optionally of one source), by start."
  def list_imported_bookings(service_uuid, external_source \\ nil) do
    from(b in Booking,
      where: b.service_uuid == ^service_uuid and b.source == "import",
      order_by: [asc: b.starts_at, asc: b.starts_on]
    )
    |> maybe_source(external_source)
    |> repo().all()
  end

  defp maybe_source(query, nil), do: query
  defp maybe_source(query, source), do: from(r in query, where: r.external_source == ^source)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
