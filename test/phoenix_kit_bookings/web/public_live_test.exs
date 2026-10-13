defmodule PhoenixKitBookings.Web.PublicLiveTest do
  use PhoenixKitBookings.LiveCase, async: true

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Users.Role
  alias PhoenixKitBookings.Bookings

  describe "public services index" do
    test "lists only active services", %{conn: conn} do
      active = slot_service_fixture()
      inactive = slot_service_fixture()
      {:ok, _} = PhoenixKitBookings.Services.set_status(inactive, "inactive")

      {:ok, _view, html} = live(conn, "/bookings")

      assert html =~ active.name
      refute html =~ inactive.name
    end

    test "a message not meant for the page leaves it running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/bookings")
      send(view.pid, {:email, %{to: "someone@example.com"}})
      assert Process.alive?(view.pid)
    end
  end

  describe "book page — admin edit link" do
    # The test host layout renders `#test-admin-edit` only when the layout
    # itself was handed `admin_edit_url`, so this proves the whole path
    # (socket assign -> `module_assigns` -> `app_layout` -> host layout).
    defp edit_link(html) do
      case Regex.run(~r/<a[^>]*id="test-admin-edit"[^>]*>(.*?)<\/a>/s, html) do
        nil -> nil
        [tag, text] -> {tag, String.trim(text)}
      end
    end

    # `fake_scope/1` models roles as a MapSet of atoms, which core's
    # `can_access_admin_area?/1` (the helper's first gate) does not read: it
    # wants the list of role-name strings a real scope carries.
    defp admin_scope(opts) do
      owner = Role.system_roles().owner
      struct!(fake_scope(opts), cached_roles: [owner])
    end

    # A non-system-role user: reaches the admin area through permissions alone.
    defp member_scope(opts), do: struct!(fake_scope(opts), cached_roles: [])

    defp create_real_user do
      {:ok, %{rows: [[uuid]]}} =
        SQL.query(
          PhoenixKitBookings.Test.Repo,
          "INSERT INTO phoenix_kit_users (email, hashed_password, inserted_at, updated_at) " <>
            "VALUES ($1, 'x', NOW(), NOW()) RETURNING uuid",
          ["lv-owner-#{System.unique_integer([:positive])}@example.com"]
        )

      Ecto.UUID.load!(uuid)
    end

    test "a site-wide manager gets the service editor in the layout", %{conn: conn} do
      service = slot_service_fixture()
      conn = put_test_scope(conn, admin_scope([]))

      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert {tag, "Edit service"} = edit_link(html)
      assert tag =~ ~s(href="#{PhoenixKitBookings.Paths.admin_service_edit(service.uuid)}")
    end

    test "the owner of the service gets it with the base permission only", %{conn: conn} do
      owner_uuid = create_real_user()

      {:ok, service} =
        PhoenixKitBookings.Services.create_service(%{"name" => unique_name("Owned")},
          owner_uuid: owner_uuid
        )

      conn =
        put_test_scope(
          conn,
          fake_scope(user_uuid: owner_uuid, permissions: ["bookings"])
          |> struct!(cached_roles: [])
        )

      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert {_, _} = edit_link(html)
    end

    test "a base-permission holder who does not own the service gets nothing", %{conn: conn} do
      service = slot_service_fixture()
      conn = put_test_scope(conn, member_scope(permissions: ["bookings"]))

      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert is_nil(edit_link(html))
    end

    test "an admin without the bookings key gets nothing", %{conn: conn} do
      service = slot_service_fixture()
      conn = put_test_scope(conn, admin_scope(permissions: ["shop"]))

      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert is_nil(edit_link(html))
    end

    test "the owner of the service still needs the bookings key", %{conn: conn} do
      owner_uuid = create_real_user()

      {:ok, service} =
        PhoenixKitBookings.Services.create_service(%{"name" => unique_name("Owned")},
          owner_uuid: owner_uuid
        )

      conn = put_test_scope(conn, member_scope(user_uuid: owner_uuid, permissions: ["shop"]))

      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert is_nil(edit_link(html))
    end

    test "an anonymous visitor gets nothing", %{conn: conn} do
      service = slot_service_fixture()

      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert is_nil(edit_link(html))
    end

    test "an unknown slug gets no link even for a manager", %{conn: conn} do
      conn = put_test_scope(conn, admin_scope([]))

      {:ok, _view, html} = live(conn, "/book/no-such-service")

      assert html =~ "does not exist"
      assert is_nil(edit_link(html))
    end

    test "patching from an owned service clears the link for an unowned service", %{conn: conn} do
      owner_uuid = create_real_user()

      {:ok, owned} =
        PhoenixKitBookings.Services.create_service(%{"name" => unique_name("Owned")},
          owner_uuid: owner_uuid
        )

      unowned = slot_service_fixture()
      conn = put_test_scope(conn, member_scope(user_uuid: owner_uuid, permissions: ["bookings"]))
      {:ok, view, html} = live(conn, "/book/#{owned.slug}")
      assert edit_link(html)

      html = render_patch(view, "/book/#{unowned.slug}")
      assert html =~ unowned.name
      assert is_nil(edit_link(html))

      html = render_patch(view, "/book/#{owned.slug}")
      assert {tag, "Edit service"} = edit_link(html)
      assert tag =~ ~s(href="#{PhoenixKitBookings.Paths.admin_service_edit(owned.uuid)}")
    end

    test "patching to an unknown slug clears the link", %{conn: conn} do
      service = slot_service_fixture()
      conn = put_test_scope(conn, admin_scope([]))
      {:ok, view, html} = live(conn, "/book/#{service.slug}")
      assert edit_link(html)

      html = render_patch(view, "/book/no-such-service")
      assert html =~ "does not exist"
      assert is_nil(edit_link(html))
    end

    test "a manager with permissions and no system role gets the link", %{conn: conn} do
      service = slot_service_fixture()
      conn = put_test_scope(conn, member_scope([]))
      {:ok, _view, html} = live(conn, "/book/#{service.slug}")

      assert {tag, "Edit service"} = edit_link(html)
      assert tag =~ ~s(href="#{PhoenixKitBookings.Paths.admin_service_edit(service.uuid)}")
    end
  end

  describe "book page — navigation cleanup" do
    test "reloading the flow releases its hold and switches its subscription", %{conn: conn} do
      first = slot_service_fixture()
      second = slot_service_fixture()
      {:ok, view, _html} = live(conn, "/book/#{first.slug}")
      tomorrow = Date.add(Date.utc_today(), 1)
      starts_at = DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")
      range = {starts_at, DateTime.add(starts_at, 3600, :second)}
      pubsub = PhoenixKit.Config.pubsub_server()

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      view
      |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
      |> render_click()

      assert [_hold] = Bookings.list_occupancy(first.uuid, range)
      render_patch(view, "/book/#{second.slug}")

      assert Bookings.list_occupancy(first.uuid, range) == []
      refute {view.pid, nil} in Registry.lookup(pubsub, Bookings.service_topic(first.uuid))
      assert {view.pid, nil} in Registry.lookup(pubsub, Bookings.service_topic(second.uuid))

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      view
      |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
      |> render_click()

      assert [_hold] = Bookings.list_occupancy(second.uuid, range)
      render_patch(view, "/book/no-such-service")
      assert Bookings.list_occupancy(second.uuid, range) == []
      refute {view.pid, nil} in Registry.lookup(pubsub, Bookings.service_topic(second.uuid))

      # A notification already queued before unsubscribe must be harmless.
      send(view.pid, {:bookings_changed, second.uuid})
      assert render(view) =~ "does not exist"

      # A click in flight from the previous picker must be harmless as well.
      assert render_click(view, "pick_slot", %{"start" => "10:00", "end" => "11:00"}) =~
               "does not exist"
    end

    test "an unknown slug ignores booking notifications", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/book/no-such-service")
      send(view.pid, {:bookings_changed, Ecto.UUID.generate()})
      assert render(view) =~ "does not exist"
    end
  end

  describe "book page — fixed slots" do
    test "full happy path: pick a slot, submit details, get a manage link", %{conn: conn} do
      service = slot_service_fixture()

      {:ok, view, html} = live(conn, "/book/#{service.slug}")
      assert html =~ service.name

      # Move the picker to tomorrow (today's early slots may be in the past).
      tomorrow = Date.add(Date.utc_today(), 1)

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      html =
        view
        |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
        |> render_click()

      assert html =~ "Your name"

      html =
        view
        |> form("form[phx-submit=submit_details]", %{
          "booking" => %{
            "customer_name" => "Walk In",
            "customer_email" => "walkin@example.com"
          }
        })
        |> render_submit()

      assert html =~ "Booked!"
      assert html =~ "/bookings/manage/"

      assert [booking] = Bookings.list_bookings(service_uuid: service.uuid)
      assert booking.customer_email == "walkin@example.com"
      assert booking.status == "confirmed"
    end

    test "a taken slot is not offered", %{conn: conn} do
      service = slot_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)
      starts_at = DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")

      {:ok, _} =
        Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs()
        )

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-change=pick_date]")
        |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      refute html =~ ~s{phx-value-start="10:00:00"}
      assert html =~ ~s{phx-value-start="11:00:00"}
    end

    test "login_required service blocks anonymous visitors at selection", %{conn: conn} do
      service = slot_service_fixture(%{"signup_policy" => "login_required"})
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      html =
        view
        |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
        |> render_click()

      assert html =~ "Please log in"
    end

    test "unknown slug renders the not-found panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/book/no-such-service")
      assert html =~ "does not exist"
    end
  end

  describe "book page — nightly stays" do
    test "books a stay through the date picker", %{conn: conn} do
      service = hotel_service_fixture()
      starts_on = Date.add(Date.utc_today(), 7)
      ends_on = Date.add(starts_on, 2)

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-submit=pick_dates]", %{
          "picker" => %{
            "starts_on" => Date.to_iso8601(starts_on),
            "ends_on" => Date.to_iso8601(ends_on)
          }
        })
        |> render_submit()

      assert html =~ "2 night(s)"

      view
      |> form("form[phx-submit=submit_details]", %{
        "booking" => %{
          "customer_name" => "Hotel Guest",
          "customer_email" => "guest@example.com"
        }
      })
      |> render_submit()

      assert [booking] = Bookings.list_bookings(service_uuid: service.uuid)
      assert booking.starts_on == starts_on
      assert booking.ends_on == ends_on
    end
  end

  describe "book page — free-form" do
    test "books an arbitrary range", %{conn: conn} do
      service = freeform_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-submit=pick_free]", %{
          "picker" => %{
            "date" => Date.to_iso8601(tomorrow),
            "start_time" => "06:00",
            "end_time" => "14:00"
          }
        })
        |> render_submit()

      assert html =~ "Your name"

      view
      |> form("form[phx-submit=submit_details]", %{
        "booking" => %{
          "customer_name" => "Lifter",
          "customer_email" => "lifter@example.com"
        }
      })
      |> render_submit()

      assert [booking] = Bookings.list_bookings(service_uuid: service.uuid)
      assert DateTime.diff(booking.ends_at, booking.starts_at, :hour) == 8
    end

    test "refuses a span the site's zone would not store as picked", %{conn: conn} do
      # A free-form service has no slot grid, so the grid's daylight-saving
      # guard never sees this pick: 02:30–03:30 on a spring-forward Sunday
      # would be stored as thirty minutes (03:00–03:59 never happens), or
      # ninety on the fall-back one.
      {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "Europe/Tallinn")
      service = freeform_service_fixture()
      gap_date = next_spring_forward()

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-submit=pick_free]", %{
          "picker" => %{
            "date" => Date.to_iso8601(gap_date),
            "start_time" => "02:30",
            "end_time" => "03:30"
          }
        })
        |> render_submit()

      refute html =~ "Your name"
      assert Bookings.list_bookings(service_uuid: service.uuid) == []

      # The same service takes an ordinary span on the very same day.
      html =
        view
        |> form("form[phx-submit=pick_free]", %{
          "picker" => %{
            "date" => Date.to_iso8601(gap_date),
            "start_time" => "10:00",
            "end_time" => "11:00"
          }
        })
        |> render_submit()

      assert html =~ "Your name"
    end
  end

  describe "manage page" do
    test "shows the booking and cancels it", %{conn: conn} do
      service = slot_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)
      starts_at = DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")

      {:ok, booking} =
        Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs()
        )

      token = Bookings.manage_token(booking)

      {:ok, view, html} = live(conn, "/bookings/manage/#{token}")
      assert html =~ booking.customer_name

      html = view |> element(~s{button[phx-click="cancel"]}) |> render_click()
      assert html =~ "cancelled"
      assert Bookings.get_booking(booking.uuid).status == "cancelled"
    end

    test "garbage tokens get the invalid-link panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/bookings/manage/garbage")
      assert html =~ "invalid or has expired"
    end
  end

  describe "embeddable widget" do
    test "mounts via live_isolated and books end to end", %{conn: conn} do
      service = slot_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, view, html} =
        live_isolated(conn, PhoenixKitBookings.Web.Public.BookingWidgetLive,
          session: %{"slug" => service.slug}
        )

      assert html =~ service.name

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      view
      |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
      |> render_click()

      html =
        view
        |> form("form[phx-submit=submit_details]", %{
          "booking" => %{
            "customer_name" => "Embedded Guest",
            "customer_email" => "embed@example.com"
          }
        })
        |> render_submit()

      assert html =~ "Booked!"
      assert [_booking] = Bookings.list_bookings(service_uuid: service.uuid)
    end

    test "widget with an unknown slug shows the unavailable panel", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitBookings.Web.Public.BookingWidgetLive,
          session: %{"slug" => "nope"}
        )

      assert html =~ "not currently taking bookings"
    end
  end

  # The next date whose 02:30–03:30 the site's zone cannot store as an hour —
  # computed rather than hard-coded so the test keeps meaning after the date
  # passes.
  defp next_spring_forward do
    today = Date.utc_today()
    offset = Enum.find(1..400, &(not intact?(Date.add(today, &1))))
    Date.add(today, offset)
  end

  defp intact?(date) do
    PhoenixKitBookings.Engine.frame_span_intact?(
      date,
      ~T[02:30:00],
      date,
      ~T[03:30:00],
      "Europe/Tallinn"
    )
  end
end
