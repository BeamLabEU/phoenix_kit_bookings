defmodule PhoenixKitBookings.ICalImport do
  @moduledoc """
  Imports an external iCal (ICS) feed as busy time of a service.

  A service with an `ical_url` is synced by `sync_service/2` — from the
  admin's "Sync now", and periodically by `Workers.ICalSyncWorker` (an hourly
  cron the module declares, `oban_crons/0`, on its own `bookings_sync` queue,
  `oban_queues/0`). One sync:

  1. fetches the feed (`ICalImport.Fetcher`, swappable — tests never touch
     the network),
  2. parses its VEVENTs (`ICalImport.Parser`; its moduledoc lists what is
     and is not understood) over a window from yesterday to
     `@horizon_days` ahead,
  3. maps each occurrence onto the service's shape — a timed event on a
     minute service stays timed; an all-day event there covers the site-frame
     day(s); on a day/night service every event covers the dates it touches,
  4. hands the full list to `Imports.sync_bookings/4` under
     `external_source: "ical"`, which inserts, updates and REMOVES only the
     rows of that source, never the owner's own,
  5. stamps `ical_synced_at` and `ical_sync_error` (nil on success) on the
     service.

  Each imported occurrence holds one seat. `external_id` is the event's UID
  (plus the occurrence's start for a recurring event), hashed when longer
  than the column allows.
  """

  use Gettext, backend: PhoenixKitBookings.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKitBookings.{Engine, Imports}
  alias PhoenixKitBookings.ICalImport.{Fetcher, Parser}
  alias PhoenixKitBookings.Schemas.Service

  @external_source "ical"
  @horizon_days 365

  def external_source, do: @external_source

  @doc """
  Fetches, parses and imports the service's feed. Returns
  `{:ok, %{inserted, updated, deleted, events, unsupported}}` or
  `{:error, reason}` (also stamped on the service as `ical_sync_error`).
  A service without a URL returns `{:error, :no_url}` and changes nothing.

  Options: `:actor_uuid`, `:now` (test injection), `:tz` (the site zone).
  """
  def sync_service(%Service{ical_url: url} = service, opts \\ []) do
    if url in [nil, ""] do
      {:error, :no_url}
    else
      service
      |> do_sync(url, opts)
      |> tap(&stamp(service, &1))
    end
  end

  defp do_sync(service, url, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    tz = Keyword.get(opts, :tz, Engine.site_tz())

    with {:ok, body} <- fetch(url),
         {:ok, %{events: events, unsupported: unsupported}} <-
           Parser.parse(body,
             from: DateTime.add(now, -1, :day),
             until: DateTime.add(now, @horizon_days, :day),
             tz: floating_zone(tz)
           ),
         entries = Enum.flat_map(events, &to_entry(&1, service, tz)),
         {:ok, stats} <-
           Imports.sync_bookings(
             service,
             @external_source,
             entries,
             Keyword.take(opts, [:actor_uuid])
           ) do
      {:ok, Map.merge(stats, %{events: length(entries), unsupported: unsupported})}
    else
      {:error, {external_id, %Ecto.Changeset{}}} -> {:error, {:invalid_entry, external_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(url) do
    Fetcher.impl().fetch(normalize_url(url))
  rescue
    e -> {:error, e}
  end

  @doc "A `webcal://` link is the same feed over https."
  def normalize_url("webcal://" <> rest), do: "https://" <> rest
  def normalize_url("webcals://" <> rest), do: "https://" <> rest
  def normalize_url(url), do: url

  # Floating times are site-frame wall clocks; a legacy fixed-offset site
  # setting is not an IANA zone the parser can use, so those read as UTC.
  defp floating_zone(tz) when is_binary(tz) do
    case DateTime.from_naive(~N[2000-01-01 00:00:00], tz, Tz.TimeZoneDatabase) do
      {:ok, _} -> tz
      _ -> "Etc/UTC"
    end
  end

  defp floating_zone(_tz), do: "Etc/UTC"

  # ── Mapping onto the service's shape ─────────────────────────────────

  defp to_entry(%{range: range} = event, %Service{time_unit: "minutes"}, tz) do
    case range do
      {:datetime, starts, ends} ->
        [entry(event, {starts, ends})]

      {:date, first, after_last} ->
        [
          entry(
            event,
            {Engine.from_frame(first, ~T[00:00:00], tz),
             Engine.from_frame(after_last, ~T[00:00:00], tz)}
          )
        ]
    end
  end

  defp to_entry(%{range: range} = event, %Service{}, tz) do
    case range do
      {:date, first, after_last} ->
        [entry(event, {:dates, first, after_last})]

      {:datetime, starts, ends} ->
        first = starts |> Engine.to_frame(tz) |> DateTime.to_date()

        last_instant =
          ends |> DateTime.add(-1, :second) |> Engine.to_frame(tz) |> DateTime.to_date()

        [entry(event, {:dates, first, Date.add(last_instant, 1)})]
    end
  end

  defp entry(event, range) do
    %{
      external_id: external_id(event),
      range: range,
      customer_name: truncate(event.summary, 255),
      metadata: %{"ical_uid" => event.uid}
    }
  end

  defp external_id(%{uid: uid, recurrence_id: nil}), do: fit(uid)
  defp external_id(%{uid: uid, recurrence_id: rid}), do: fit("#{uid}@#{instant_id(rid)}")

  defp instant_id({:date, date}), do: Date.to_iso8601(date, :basic)

  defp instant_id({:local, naive, zone}),
    do: naive |> naive_utc(zone) |> Calendar.strftime("%Y%m%dT%H%M%SZ")

  defp naive_utc(naive, zone) do
    case DateTime.from_naive(naive, zone, Tz.TimeZoneDatabase) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC", Tz.TimeZoneDatabase)
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC", Tz.TimeZoneDatabase)
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC", Tz.TimeZoneDatabase)
      _ -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  # The column holds 255; a longer id is replaced by its digest.
  defp fit(id) when byte_size(id) <= 255, do: id
  defp fit(id), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, id), case: :lower)

  defp truncate(nil, _), do: nil
  defp truncate(text, max), do: String.slice(text, 0, max)

  # ── Bookkeeping ──────────────────────────────────────────────────────

  defp stamp(%Service{uuid: uuid}, result) do
    error =
      case result do
        {:ok, _} -> nil
        {:error, reason} -> reason |> describe() |> String.slice(0, 1000)
      end

    if error, do: Logger.warning("[Bookings] iCal sync of #{uuid} failed: #{error}")

    from(s in Service, where: s.uuid == ^uuid)
    |> repo().update_all(
      set: [
        ical_synced_at: DateTime.truncate(DateTime.utc_now(), :second),
        ical_sync_error: error
      ]
    )
  rescue
    _ -> :ok
  end

  @doc "A sync failure in words (stored on the service, shown in the admin)."
  def describe(:not_a_calendar), do: gettext("The URL did not return an iCal calendar.")
  def describe(:too_large), do: gettext("The feed is larger than 5 MB.")

  def describe(:no_url), do: gettext("No feed URL is set.")

  def describe(:blocked_host),
    do:
      gettext(
        "The feed's address is on a private or local network; only public addresses are fetched."
      )

  def describe(:nxdomain), do: gettext("The feed's host name could not be found.")
  def describe(:invalid_url), do: gettext("The feed URL is not valid.")

  def describe(:scheme_not_allowed),
    do: gettext("The feed URL must use http or https (an https feed cannot redirect to http).")

  def describe(:port_not_allowed), do: gettext("The feed URL uses a port that is not allowed.")
  def describe(:too_many_redirects), do: gettext("The feed redirected too many times.")
  def describe(:timeout), do: gettext("The feed did not answer in time.")

  def describe({:connect_failed, _}), do: gettext("The feed's server could not be reached.")

  def describe({:http_status, status}),
    do: gettext("The feed answered HTTP %{status}.", status: status)

  def describe({:invalid_entry, id}),
    do: gettext("The feed entry %{id} could not be stored.", id: id)

  def describe(%{__exception__: true} = e), do: Exception.message(e)
  def describe(other), do: inspect(other)

  @doc "Services with a feed URL that are not trashed — what the cron syncs."
  def list_feed_services do
    from(s in Service, where: not is_nil(s.ical_url) and s.status != "trashed")
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
