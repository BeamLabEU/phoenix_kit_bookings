defmodule PhoenixKitBookings.ICalImport.SyncTest do
  # Not async: the fetcher is swapped through the application env.
  use PhoenixKitBookings.DataCase, async: false

  alias PhoenixKitBookings.{ICalImport, Imports, Services}
  alias PhoenixKitBookings.Workers.ICalSyncWorker

  defmodule FakeFetcher do
    @moduledoc false
    @behaviour PhoenixKitBookings.ICalImport.Fetcher

    @impl true
    def fetch(url) do
      send(self(), {:fetched, url})

      case Process.get(:ical_response) do
        nil -> {:error, :no_response_set}
        response -> response
      end
    end
  end

  setup do
    previous = Application.get_env(:phoenix_kit_bookings, :ical_fetcher)
    Application.put_env(:phoenix_kit_bookings, :ical_fetcher, FakeFetcher)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_bookings, :ical_fetcher, previous),
        else: Application.delete_env(:phoenix_kit_bookings, :ical_fetcher)
    end)

    :ok
  end

  defp feed(events) do
    body =
      Enum.map_join(events, "", fn {uid, start, finish} ->
        "BEGIN:VEVENT\r\nUID:#{uid}\r\nDTSTART:#{stamp(start)}\r\nDTEND:#{stamp(finish)}\r\n" <>
          "SUMMARY:Busy #{uid}\r\nEND:VEVENT\r\n"
      end)

    {:ok, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" <> body <> "END:VCALENDAR\r\n"}
  end

  defp stamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  defp stamp(%Date{} = d), do: Calendar.strftime(d, "%Y%m%d")

  defp at(days, hour) do
    Date.utc_today() |> Date.add(days) |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  test "imports the feed's busy times and removes the ones that disappeared" do
    service = slot_service_fixture(%{"ical_url" => "webcal://cal.example.com/feed.ics"})

    Process.put(:ical_response, feed([{"a", at(1, 10), at(1, 11)}, {"b", at(2, 10), at(2, 11)}]))
    assert {:ok, %{inserted: 2, deleted: 0, events: 2}} = ICalImport.sync_service(service)
    assert_received {:fetched, "https://cal.example.com/feed.ics"}

    [a | _] = Imports.list_imported_bookings(service.uuid, "ical")
    assert a.external_id == "a"
    assert a.customer_name == "Busy a"
    assert a.starts_at == at(1, 10)

    Process.put(:ical_response, feed([{"b", at(2, 10), at(2, 11)}]))
    assert {:ok, %{deleted: 1, inserted: 0}} = ICalImport.sync_service(service)
    assert [%{external_id: "b"}] = Imports.list_imported_bookings(service.uuid, "ical")

    reloaded = Services.get_service(service.uuid)
    assert reloaded.ical_synced_at
    assert reloaded.ical_sync_error == nil
  end

  test "on a night service an event covers the dates it touches" do
    hotel = hotel_service_fixture(%{"ical_url" => "https://cal.example.com/h.ics"})
    d = Date.add(Date.utc_today(), 3)

    Process.put(
      :ical_response,
      feed([{"stay", d, Date.add(d, 2)}, {"timed", at(5, 14), at(6, 10)}])
    )

    assert {:ok, %{inserted: 2}} = ICalImport.sync_service(hotel)

    rows = Map.new(Imports.list_imported_bookings(hotel.uuid), &{&1.external_id, &1})
    assert {rows["stay"].starts_on, rows["stay"].ends_on} == {d, Date.add(d, 2)}

    assert {rows["timed"].starts_on, rows["timed"].ends_on} ==
             {Date.add(Date.utc_today(), 5), Date.add(Date.utc_today(), 7)}
  end

  test "an all-day event on a minute service covers the whole day" do
    service = freeform_service_fixture(%{"ical_url" => "https://cal.example.com/c.ics"})
    d = Date.add(Date.utc_today(), 2)

    Process.put(:ical_response, feed([{"day", d, Date.add(d, 1)}]))
    {:ok, _} = ICalImport.sync_service(service)

    assert [%{starts_at: s, ends_at: e}] = Imports.list_imported_bookings(service.uuid)
    assert s == DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
    assert e == DateTime.new!(Date.add(d, 1), ~T[00:00:00], "Etc/UTC")
  end

  test "a failing feed changes no rows and records the error" do
    service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/x.ics"})
    Process.put(:ical_response, feed([{"a", at(1, 10), at(1, 11)}]))
    {:ok, _} = ICalImport.sync_service(service)

    Process.put(:ical_response, {:error, {:http_status, 503}})
    assert {:error, {:http_status, 503}} = ICalImport.sync_service(service)
    assert [_] = Imports.list_imported_bookings(service.uuid)
    assert Services.get_service(service.uuid).ical_sync_error =~ "503"

    Process.put(:ical_response, {:ok, "<html>login</html>"})
    assert {:error, :not_a_calendar} = ICalImport.sync_service(service)
    assert [_] = Imports.list_imported_bookings(service.uuid)
  end

  test "a response from a replaced feed cannot change occupancy or the new feed status" do
    service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/old.ics"})

    {:ok, current} =
      Services.update_service(service, %{"ical_url" => "https://cal.example.com/new.ics"})

    Process.put(:ical_response, feed([{"new", at(1, 10), at(1, 11)}]))
    assert {:ok, %{inserted: 1}} = ICalImport.sync_service(current)

    Process.put(:ical_response, feed([]))
    assert {:error, :service_changed} = ICalImport.sync_service(service)
    assert [%{external_id: "new"}] = Imports.list_imported_bookings(current.uuid)
    assert Services.get_service(current.uuid).ical_sync_error == nil
  end

  test "a read that began before the last applied one is dropped, not applied" do
    service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/x.ics"})
    newer = DateTime.utc_now()

    Process.put(:ical_response, feed([{"a", at(1, 10), at(1, 11)}]))
    {:ok, %{inserted: 1}} = ICalImport.sync_service(service, fetched_at: newer)

    Process.put(:ical_response, feed([]))

    assert {:ok, %{stale: true, deleted: 0}} =
             ICalImport.sync_service(service, fetched_at: DateTime.add(newer, -30))

    assert [_] = Imports.list_imported_bookings(service.uuid)
    assert Services.get_service(service.uuid).ical_sync_error == nil
  end

  test "a recurring event in the feed's own VTIMEZONE imports with stable ids" do
    service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/v.ics"})
    day = Date.utc_today() |> Date.add(2) |> Calendar.strftime("%Y%m%d")

    body =
      "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:Office\r\nBEGIN:STANDARD\r\n" <>
        "DTSTART:19700101T000000\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0200\r\n" <>
        "END:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:rec\r\n" <>
        "DTSTART;TZID=Office:#{day}T100000\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY;COUNT=2\r\n" <>
        "END:VEVENT\r\nEND:VCALENDAR\r\n"

    Process.put(:ical_response, {:ok, body})
    assert {:ok, %{inserted: 2, unsupported: 0}} = ICalImport.sync_service(service)
    assert {:ok, %{inserted: 0, updated: 0}} = ICalImport.sync_service(service)

    [first | _] = Imports.list_imported_bookings(service.uuid, "ical")
    assert first.external_id == "rec@#{day}T080000Z"
  end

  test "no URL, no sync" do
    assert {:error, :no_url} = ICalImport.sync_service(slot_service_fixture())
    refute_received {:fetched, _}
  end

  test "an over-long UID is stored as its digest, stable across syncs" do
    service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/l.ics"})
    uid = String.duplicate("x", 300)

    Process.put(:ical_response, feed([{uid, at(1, 10), at(1, 11)}]))
    {:ok, %{inserted: 1}} = ICalImport.sync_service(service)
    assert {:ok, %{inserted: 0, updated: 0}} = ICalImport.sync_service(service)

    assert [%{external_id: "sha256:" <> _}] = Imports.list_imported_bookings(service.uuid)
  end

  test "the URL must be http(s) or webcal" do
    assert {:error, cs} =
             Services.create_service(%{"name" => "x", "ical_url" => "file:///etc/passwd"})

    assert errors_on(cs)[:ical_url]
  end

  test "the URL may not name localhost or a private address literal" do
    for url <- [
          "http://localhost/x.ics",
          "http://127.0.0.1/x.ics",
          "https://169.254.169.254/latest",
          "webcal://[::1]/x.ics"
        ] do
      assert {:error, cs} = Services.create_service(%{"name" => "x", "ical_url" => url}), url
      assert errors_on(cs)[:ical_url] == ["must not point to a private or local address"]
    end
  end

  test "the default fetcher refuses a stored URL whose host resolves inside, and says so" do
    Application.delete_env(:phoenix_kit_bookings, :ical_fetcher)
    service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/x.ics"})

    # Stored before any check (an older row, or written around the changeset).
    {1, _} =
      PhoenixKit.RepoHelper.repo().update_all(
        from(s in PhoenixKitBookings.Schemas.Service, where: s.uuid == ^service.uuid),
        set: [ical_url: "http://localhost/x.ics"]
      )

    service = Services.get_service(service.uuid)
    assert {:error, :blocked_host} = ICalImport.sync_service(service)
    assert Services.get_service(service.uuid).ical_sync_error =~ "private or local network"
  end

  describe "ICalSyncWorker" do
    test "a service job syncs that service" do
      service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/w.ics"})
      Process.put(:ical_response, feed([{"a", at(1, 10), at(1, 11)}]))

      assert :ok = ICalSyncWorker.perform(%Oban.Job{args: %{"service_uuid" => service.uuid}})
      assert [_] = Imports.list_imported_bookings(service.uuid)
    end

    test "the module declares the worker's queue and its cron" do
      assert Keyword.has_key?(PhoenixKitBookings.oban_queues(), :bookings_sync)

      assert {_cron, ICalSyncWorker} =
               List.keyfind(PhoenixKitBookings.oban_crons(), ICalSyncWorker, 1)

      assert ICalSyncWorker.__opts__()[:queue] == :bookings_sync
    end
  end
end
