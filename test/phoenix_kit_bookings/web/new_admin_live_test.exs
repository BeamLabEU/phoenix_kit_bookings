defmodule PhoenixKitBookings.Web.NewAdminLiveTest do
  @moduledoc "Admin surfaces added in V3: events, hosts, and the service form's new cards."
  use PhoenixKitBookings.LiveCase, async: false

  alias PhoenixKitBookings.{
    Bookings,
    Events,
    HostProfiles,
    Imports,
    PriceOptions,
    RegularSlots,
    Services
  }

  defmodule FakeFetcher do
    @moduledoc false
    @behaviour PhoenixKitBookings.ICalImport.Fetcher
    @impl true
    def fetch(_url) do
      day = Date.utc_today() |> Date.add(2) |> Calendar.strftime("%Y%m%d")

      {:ok,
       "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:one\r\nDTSTART;VALUE=DATE:#{day}\r\n" <>
         "END:VEVENT\r\nEND:VCALENDAR\r\n"}
    end
  end

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  describe "service form" do
    test "saves host_ref, the availability-only switch and the feed URL", %{conn: conn} do
      service = slot_service_fixture()
      {:ok, view, _} = live(conn, "/en/admin/bookings/services/#{service.uuid}/edit")

      view
      |> form("#bookings-service-form", %{
        "service" => %{
          "host_ref" => "machine:7",
          "bookable_online" => "false",
          "ical_url" => "https://cal.example.com/x.ics"
        }
      })
      |> render_submit()

      saved = Services.get_service(service.uuid)
      assert saved.host_ref == "machine:7"
      assert saved.bookable_online == false
      assert saved.ical_url == "https://cal.example.com/x.ics"
    end

    test "adds a price option for chosen accounts and a regular slot", %{conn: conn} do
      service = slot_service_fixture()
      client = user_fixture()
      {:ok, view, _} = live(conn, "/en/admin/bookings/services/#{service.uuid}/edit")

      html =
        view
        |> form("#bookings-add-price-option", %{
          "price_option" => %{
            "name" => "Solo",
            "price" => "25",
            "entitlement" => "users",
            "user_emails" => client.email
          }
        })
        |> render_submit()

      assert html =~ "Price option added."
      assert [%{user_uuids: [uuid]}] = PriceOptions.list_options(service.uuid)
      assert uuid == client.uuid

      html =
        view
        |> form("#bookings-add-regular-slot", %{
          "regular_slot" => %{
            "day_of_week" => "2",
            "start_time" => "18:00",
            "end_time" => "19:00",
            "customer_name" => "Mari",
            "customer_email" => "mari@example.com"
          }
        })
        |> render_submit()

      assert html =~ "Regular slot added."
      assert [%{day_of_week: 2, customer_name: "Mari"}] = RegularSlots.list_slots(service.uuid)
    end

    test "Sync now imports the feed", %{conn: conn} do
      previous = Application.get_env(:phoenix_kit_bookings, :ical_fetcher)
      Application.put_env(:phoenix_kit_bookings, :ical_fetcher, FakeFetcher)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_bookings, :ical_fetcher, previous),
          else: Application.delete_env(:phoenix_kit_bookings, :ical_fetcher)
      end)

      service = slot_service_fixture(%{"ical_url" => "https://cal.example.com/x.ics"})
      {:ok, view, _} = live(conn, "/en/admin/bookings/services/#{service.uuid}/edit")

      view |> element("#bookings-sync-ical") |> render_click()
      html = render_async(view, 5_000)

      assert html =~ "Calendar synced: 1 added"
      assert [_] = Imports.list_imported_bookings(service.uuid, "ical")
    end
  end

  test "reservations mark imported rows and regular-slot conflicts", %{conn: conn} do
    service = slot_service_fixture()
    day = Date.add(Date.utc_today(), 2)

    {:ok, _} =
      Imports.sync_bookings(service, "ical", [
        %{
          external_id: "1",
          range:
            {DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
             DateTime.new!(day, ~T[11:00:00], "Etc/UTC")}
        }
      ])

    {:ok, _} =
      RegularSlots.create_slot(service, %{
        "day_of_week" => Date.day_of_week(day),
        "start_time" => "12:00:00",
        "end_time" => "13:00:00",
        "customer_email" => "regular@example.com"
      })

    {:ok, _} =
      Bookings.create_booking(
        service,
        {DateTime.new!(day, ~T[12:00:00], "Etc/UTC"),
         DateTime.new!(day, ~T[13:00:00], "Etc/UTC")},
        customer_attrs(),
        notify: false
      )

    {:ok, _view, html} = live(conn, "/en/admin/bookings/reservations")
    assert html =~ "imported (ical)"
    assert html =~ "in a regular slot"
  end

  describe "events page" do
    test "creates an event in the site frame and cancels it", %{conn: conn} do
      service = slot_service_fixture()
      {:ok, view, _} = live(conn, "/en/admin/bookings/events")

      day = Date.add(Date.utc_today(), 4) |> Date.to_iso8601()

      html =
        view
        |> form("#bookings-event-form", %{
          "event" => %{
            "service_uuid" => service.uuid,
            "title" => "Open training",
            "starts_local" => "#{day}T18:00",
            "ends_local" => "#{day}T19:30",
            "capacity" => "8"
          }
        })
        |> render_submit()

      assert html =~ "Event saved."
      assert [event] = Events.list_events(service_uuids: [service.uuid])
      assert event.capacity == 8
      assert event.starts_at == DateTime.new!(Date.from_iso8601!(day), ~T[18:00:00], "Etc/UTC")

      html = view |> element(~s{button[phx-click="cancel_event"]}) |> render_click()
      assert html =~ "Event cancelled."
      assert Events.get_event(event.uuid).status == "cancelled"
    end

    test "an own-services user cannot add events to someone else's service", %{conn: conn} do
      service = slot_service_fixture()
      mine_owner = user_fixture()

      {:ok, mine} =
        Services.create_service(%{"name" => unique_name("Mine")}, owner_uuid: mine_owner.uuid)

      conn =
        put_test_scope(conn, fake_scope(user_uuid: mine_owner.uuid, permissions: ["bookings"]))

      {:ok, view, html} = live(conn, "/en/admin/bookings/events")
      assert html =~ mine.name
      refute html =~ service.name

      render_submit(view, "save", %{
        "event" => %{
          "service_uuid" => service.uuid,
          "title" => "Sneaky",
          "starts_local" => "2030-01-01T10:00",
          "ends_local" => "2030-01-01T11:00"
        }
      })

      assert Events.list_events(service_uuids: [service.uuid]) == []
    end
  end

  describe "hosts page" do
    test "a manager creates a profile", %{conn: conn} do
      {:ok, view, _} = live(conn, "/en/admin/bookings/hosts")

      html =
        view
        |> form("#bookings-host-form", %{
          "host_profile" => %{"name" => "Kati Kask", "headline" => "Trainer"}
        })
        |> render_submit()

      assert html =~ "Host profile saved."
      assert [%{slug: "kati-kask"}] = HostProfiles.list_profiles()
    end

    test "an own-services user is sent away", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["bookings"]))
      assert {:error, {:live_redirect, _}} = live(conn, "/en/admin/bookings/hosts")
    end
  end
end
