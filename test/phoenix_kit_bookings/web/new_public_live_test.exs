defmodule PhoenixKitBookings.Web.NewPublicLiveTest do
  @moduledoc "Public pages added in V3: price options, availability mode, schedule, hosts, events."
  use PhoenixKitBookings.LiveCase, async: true

  alias PhoenixKitBookings.{Bookings, Events, HostProfiles, Imports, PriceOptions, Services}

  defp tomorrow, do: Date.add(Date.utc_today(), 1)

  defp to_details(view) do
    view
    |> form("form[phx-change=pick_date]")
    |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow())}})

    view
    |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
    |> render_click()
  end

  describe "price options in the booking flow" do
    setup do
      service = slot_service_fixture(%{"price" => "50"})
      client = user_fixture()

      {:ok, solo} =
        PriceOptions.create_option(service, %{
          "name" => "Solo lesson rate",
          "price" => "30",
          "entitlement" => "users",
          "user_uuids" => [client.uuid]
        })

      %{service: service, client: client, solo: solo}
    end

    test "an entitled customer sees the option and books at it", %{conn: conn} = ctx do
      conn =
        put_test_scope(
          conn,
          fake_scope(user_uuid: ctx.client.uuid, email: ctx.client.email, permissions: [])
        )

      {:ok, view, _} = live(conn, "/book/#{ctx.service.slug}")

      html = to_details(view)
      assert html =~ "Solo lesson rate"

      html =
        view
        |> form("form[phx-submit=submit_details]", %{
          "booking" => %{
            "customer_name" => "Client",
            "customer_email" => ctx.client.email,
            "price_option_uuid" => ctx.solo.uuid
          }
        })
        |> render_submit()

      assert html =~ "30.00 EUR"
      assert [booking] = Bookings.list_bookings(service_uuid: ctx.service.uuid)
      assert booking.price_option_uuid == ctx.solo.uuid
    end

    test "a guest neither sees it nor can force it", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/book/#{ctx.service.slug}")

      html = to_details(view)
      refute html =~ "Solo lesson rate"

      render_submit(view, "submit_details", %{
        "booking" => %{
          "customer_name" => "Guest",
          "customer_email" => "g@example.com",
          "price_option_uuid" => ctx.solo.uuid
        }
      })

      assert [booking] = Bookings.list_bookings(service_uuid: ctx.service.uuid)
      assert booking.price_option_uuid == nil
      assert Decimal.equal?(booking.total_price, Decimal.new("50.00"))
    end
  end

  describe "availability-only services" do
    test "the routed page shows the calendar and no picker", %{conn: conn} do
      service = slot_service_fixture(%{"bookable_online" => false})
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

      {:ok, view, html} = live(conn, "/book/#{service.slug}")

      assert html =~ "data-availability-calendar"
      refute html =~ "pick_slot"
      refute html =~ ~s(phx-change="pick_date")

      # A month away and back, if the day is next month.
      html =
        if day.month != Date.utc_today().month,
          do: render_click(view, "availability_month", %{"month" => Date.to_iso8601(day)}),
          else: html

      assert html =~ ~s(data-date="#{Date.to_iso8601(day)}" data-status="partial")

      # Booking events are ignored outright.
      render_click(view, "pick_slot", %{"start" => "10:00", "end" => "11:00"})
      assert Bookings.list_bookings(service_uuid: service.uuid, status: "pending") == []
    end

    test "a public create is refused for a service not bookable online" do
      service = slot_service_fixture(%{"bookable_online" => false})
      starts = DateTime.new!(tomorrow(), ~T[10:00:00], "Etc/UTC")
      range = {starts, DateTime.add(starts, 3600)}

      assert {:error, :service_unavailable, _} =
               Bookings.create_booking(service, range, customer_attrs())

      assert {:ok, _} =
               Bookings.create_booking(service, range, customer_attrs(),
                 source: "admin",
                 notify: false
               )
    end

    test "the widget's availability mode on a bookable service", %{conn: conn} do
      service = slot_service_fixture()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitBookings.Web.Public.BookingWidgetLive,
          session: %{"slug" => service.slug, "mode" => "availability"}
        )

      assert html =~ "data-availability-calendar"
      refute html =~ "pick_date"
    end
  end

  describe "schedule, hosts and events" do
    setup do
      {:ok, host} =
        HostProfiles.create_profile(%{
          "name" => unique_name("Anna"),
          "headline" => "Yoga teacher"
        })

      service = slot_service_fixture(%{"host_profile_uuid" => host.uuid, "price" => "15"})
      starts = DateTime.new!(Date.add(Date.utc_today(), 3), ~T[18:00:00], "Etc/UTC")

      {:ok, event} =
        Events.create_event(%{
          "service_uuid" => service.uuid,
          "title" => "Evening flow",
          "starts_at" => starts,
          "ends_at" => DateTime.add(starts, 3600),
          "capacity" => 1,
          "location" => "Studio 2"
        })

      %{host: host, service: service, event: event}
    end

    test "the schedule lists the event with its host and places", %{conn: conn} = ctx do
      {:ok, _view, html} = live(conn, "/bookings/schedule")

      assert html =~ "Evening flow"
      assert html =~ ctx.host.name
      assert html =~ "1 place left"
      assert html =~ "/bookings/events/#{ctx.event.uuid}"
      assert html =~ "/bookings/hosts/#{ctx.host.slug}"
    end

    test "inactive hosts disappear from public cards and the open event", %{conn: conn} = ctx do
      {:ok, view, html} = live(conn, "/bookings/events/#{ctx.event.uuid}")
      assert html =~ ctx.host.name
      {:ok, _} = HostProfiles.update_profile(ctx.host, %{"status" => "inactive"})
      refute render(view) =~ ctx.host.name
      {:ok, _, html} = live(conn, "/bookings/schedule")
      refute html =~ ctx.host.name
    end

    test "an open event follows a move to another service and withdrawal", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/bookings/events/#{ctx.event.uuid}")
      destination = slot_service_fixture()

      {:ok, moved} =
        Events.update_event(ctx.event, %{
          "title" => "Moved class",
          "service_uuid" => destination.uuid
        })

      assert has_element?(view, "#event-details", "Moved class")
      {:ok, _} = Events.update_event(moved, %{"public" => false})
      refute has_element?(view, "#event-signup")
      assert render(view) =~ "no longer on the schedule"
    end

    test "the host page shows the profile, its events and services", %{conn: conn} = ctx do
      {:ok, _view, html} = live(conn, "/bookings/hosts/#{ctx.host.slug}")

      assert html =~ "Yoga teacher"
      assert html =~ "Evening flow"
      assert html =~ ctx.service.name

      {:ok, _view, html} = live(conn, "/bookings/hosts/nobody-here")
      assert html =~ "This profile does not exist."
    end

    test "signing up books a seat; a full event says so", %{conn: conn} = ctx do
      {:ok, view, html} = live(conn, "/bookings/events/#{ctx.event.uuid}")
      assert html =~ "Studio 2"
      assert html =~ "15.00 EUR"

      html =
        view
        |> form("#event-signup", %{
          "booking" => %{"customer_name" => "Kai", "customer_email" => "kai@example.com"}
        })
        |> render_submit()

      assert html =~ "signed up"
      assert [booking] = Bookings.list_bookings(service_uuid: ctx.service.uuid)
      assert booking.event_uuid == ctx.event.uuid

      {:ok, _view, html} = live(conn, "/bookings/events/#{ctx.event.uuid}")
      assert html =~ "This event is fully booked."
      refute html =~ "event-signup"
    end

    test "an availability-only service's event offers no sign-up form", %{conn: conn} = ctx do
      {:ok, _} = Services.update_service(ctx.service, %{"bookable_online" => false})
      {:ok, _view, html} = live(conn, "/bookings/events/#{ctx.event.uuid}")

      assert html =~ "Sign-up for this event is not taken online."
      refute html =~ "event-signup"
    end

    test "a hidden or unknown event is not found", %{conn: conn} = ctx do
      {:ok, _} = Events.update_event(ctx.event, %{"public" => false})
      {:ok, _view, html} = live(conn, "/bookings/events/#{ctx.event.uuid}")
      assert html =~ "no longer on the schedule"

      {:ok, _view, html} = live(conn, "/bookings/events/not-a-uuid")
      assert html =~ "no longer on the schedule"
    end
  end
end
