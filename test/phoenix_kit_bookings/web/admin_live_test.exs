defmodule PhoenixKitBookings.Web.AdminLiveTest do
  use PhoenixKitBookings.LiveCase, async: true

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBookings.{Bookings, Paths, Services}
  alias PhoenixKitBookings.Schemas.Service
  alias PhoenixKitBookings.Test.Repo

  defp admin_conn(conn), do: put_test_scope(conn, fake_scope())

  test "a message not meant for a page leaves it running", %{conn: conn} do
    for path <- ["/en/admin/bookings/services", "/en/admin/bookings/reservations"] do
      {:ok, view, _html} = live(admin_conn(conn), path)
      send(view.pid, {:email, %{to: "someone@example.com"}})
      assert Process.alive?(view.pid), path
    end
  end

  describe "ServicesLive" do
    test "lists services with mode summaries", %{conn: conn} do
      slot = slot_service_fixture()
      hotel = hotel_service_fixture()

      {:ok, _view, html} = live(admin_conn(conn), "/en/admin/bookings/services")

      assert html =~ slot.name
      assert html =~ hotel.name
      assert html =~ "Slots · 60 min every 60 min"
      assert html =~ "Nightly stays"
    end

    test "trash moves a service out of the default view", %{conn: conn} do
      service = slot_service_fixture()

      {:ok, view, _html} = live(admin_conn(conn), "/en/admin/bookings/services")

      html =
        view
        |> element(~s{tr#service-#{service.uuid} button[phx-click="trash"]})
        |> render_click()

      refute html =~ ~s{id="service-#{service.uuid}"}
      assert Services.get_service(service.uuid).status == "trashed"
    end
  end

  describe "ServiceFormLive" do
    test "creates a service and redirects to edit", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), "/en/admin/bookings/services/new")

      view
      |> form("form[phx-submit=save]", %{
        "service" => %{
          "name" => "Sauna Session",
          "time_unit" => "minutes",
          "duration" => "45",
          "seats" => "4"
        }
      })
      |> render_submit()

      assert service = Services.get_active_service_by_slug("sauna-session")
      assert service.duration == 45
      assert_redirect(view, Paths.admin_service_edit(service.uuid))
    end

    test "creates a service from a Cyrillic name with a romanized public slug", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), "/en/admin/bookings/services/new")

      view
      |> form("form[phx-submit=save]", %{
        "service" => %{
          "name" => "Массаж спины",
          "time_unit" => "minutes",
          "duration" => "60",
          "seats" => "1"
        }
      })
      |> render_submit()

      assert %Service{} = service = Repo.get_by(Service, name: "Массаж спины")

      assert service.slug =~ ~r/^[a-z0-9][a-z0-9-]*$/
      assert Services.get_active_service_by_slug(service.slug).uuid == service.uuid
      assert_redirect(view, Paths.admin_service_edit(service.uuid))
    end

    test "adds and removes an availability rule on the edit page", %{conn: conn} do
      service = slot_service_fixture()

      {:ok, view, _html} =
        live(admin_conn(conn), "/en/admin/bookings/services/#{service.uuid}/edit")

      view
      |> form("form[phx-submit=add_rule]", %{
        "rule" => %{
          "days_of_week" => ["1", "2"],
          "start_time" => "09:00",
          "end_time" => "17:00",
          "available" => "true"
        }
      })
      |> render_submit()

      assert [rule] = Services.list_rules(service.uuid)
      assert rule.days_of_week == [1, 2]

      view
      |> element(~s{button[phx-click="delete_rule"][phx-value-uuid="#{rule.uuid}"]})
      |> render_click()

      assert Services.list_rules(service.uuid) == []
    end
  end

  describe "admin header trail" do
    # Core's header bar draws Admin Panel / page_section / crumbs / page_title
    # from these assigns; the test layout does not render the bar, so the
    # assigns are read off the socket.
    defp trail(view) do
      assigns = :sys.get_state(view.pid).socket.assigns

      {assigns[:page_section], Enum.map(assigns[:page_crumbs] || [], & &1.label),
       assigns.page_title}
    end

    test "the reservations list is the landing page; the rest carry Bookings as the section",
         %{conn: conn} do
      service = slot_service_fixture()
      conn = admin_conn(conn)

      {:ok, view, _} = live(conn, "/en/admin/bookings/reservations")
      assert trail(view) == {nil, [], "Bookings"}

      {:ok, view, _} = live(conn, "/en/admin/bookings/services")
      assert trail(view) == {"Bookings", [], "Services"}

      {:ok, view, _} = live(conn, "/en/admin/bookings/services/new")
      assert trail(view) == {"Bookings", ["Services"], "New service"}

      {:ok, view, html} = live(conn, "/en/admin/bookings/services/#{service.uuid}/edit")
      assert trail(view) == {"Bookings", ["Services", service.name], "Edit"}
      assert html =~ "<h2 class=\"text-2xl font-bold\">#{service.name}</h2>"

      {:ok, view, _} = live(conn, "/en/admin/settings/bookings")
      assert trail(view) == {"Settings", [], "Bookings"}
    end
  end

  describe "ownership scoping" do
    test "a base-permission user sees only their own services", %{conn: conn} do
      user_uuid = create_real_user()
      site_service = slot_service_fixture()

      {:ok, owned} =
        Services.create_service(%{"name" => unique_name("My studio")}, owner_uuid: user_uuid)

      conn =
        put_test_scope(conn, fake_scope(permissions: ["bookings"], user_uuid: user_uuid))

      {:ok, _view, html} = live(conn, "/en/admin/bookings/services")

      assert html =~ owned.name
      refute html =~ site_service.name
      # Self-service is off by default — no create button.
      refute html =~ "New Service"
    end

    test "the settings page is manage_all-only", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["bookings"]))

      admin_path = Routes.path("/admin")

      assert {:error, {:live_redirect, %{to: ^admin_path}}} =
               live(conn, "/en/admin/settings/bookings")
    end
  end

  defp create_real_user do
    {:ok, %{rows: [[uuid]]}} =
      SQL.query(
        Repo,
        "INSERT INTO phoenix_kit_users (email, hashed_password, inserted_at, updated_at) " <>
          "VALUES ($1, 'x', NOW(), NOW()) RETURNING uuid",
        ["lv-owner-#{System.unique_integer([:positive])}@example.com"]
      )

    Ecto.UUID.load!(uuid)
  end

  describe "BookingsLive" do
    test "shows bookings and approves a pending one", %{conn: conn} do
      service = slot_service_fixture(%{"require_approval" => true})

      starts_at =
        Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

      {:ok, booking} =
        Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs()
        )

      assert booking.status == "pending"

      {:ok, view, html} = live(admin_conn(conn), "/en/admin/bookings/reservations")
      assert html =~ booking.customer_name

      view
      |> element(~s{tr#booking-#{booking.uuid} button[phx-click="confirm"]})
      |> render_click()

      assert Bookings.get_booking(booking.uuid).status == "confirmed"
    end
  end

  describe "service form — providers" do
    # Core 3.x creates no staff tables and the suite does not install staff, so
    # the table is made here, inside the test's transaction.
    defp staff_table! do
      SQL.query!(
        PhoenixKitBookings.Test.Repo,
        """
        CREATE TABLE phoenix_kit_staff_people (
          uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          user_uuid uuid,
          status varchar(20) NOT NULL DEFAULT 'active',
          name varchar
        )
        """
      )
    end

    defp person!(name, user_uuid \\ nil, status \\ "active") do
      %{rows: [[uuid]]} =
        SQL.query!(
          PhoenixKitBookings.Test.Repo,
          "INSERT INTO phoenix_kit_staff_people (user_uuid, status, name) " <>
            "VALUES ($1, $2, $3) RETURNING uuid::text",
          [user_uuid && Ecto.UUID.dump!(user_uuid), status, name]
        )

      uuid
    end

    defp account!(first_name, last_name, email) do
      %{rows: [[uuid]]} =
        SQL.query!(
          PhoenixKitBookings.Test.Repo,
          "INSERT INTO phoenix_kit_users (email, first_name, last_name, hashed_password, " <>
            "inserted_at, updated_at) VALUES ($1, $2, $3, 'x', NOW(), NOW()) RETURNING uuid::text",
          [email, first_name, last_name]
        )

      uuid
    end

    test "a person is named from their account when their own name is blank", %{conn: conn} do
      staff_table!()
      person!("Named Therapist")
      person!(nil, account!("Mari", "Tamm", "mari-#{System.unique_integer([:positive])}@x.ee"))

      unnamed = "plain-#{System.unique_integer([:positive])}@x.ee"
      person!(nil, account!(nil, nil, unnamed))
      person!("Left Long Ago", nil, "trashed")

      service = slot_service_fixture()
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/bookings/services/#{service.uuid}/edit")

      assert html =~ "Named Therapist"
      assert html =~ "Mari Tamm"
      assert html =~ unnamed
      refute html =~ "Left Long Ago"
    end

    test "with no staff table the select is not drawn", %{conn: conn} do
      service = slot_service_fixture()
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/bookings/services/#{service.uuid}/edit")

      refute html =~ "No provider"
    end
  end

  describe "reservations — long lists" do
    test "a list reaching into the past opens on the newest", %{conn: conn} do
      service = freeform_service_fixture()

      for days <- 3..4 do
        day = Date.add(Date.utc_today(), days)

        {:ok, _} =
          PhoenixKitBookings.Bookings.create_booking(
            service,
            {DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
             DateTime.new!(day, ~T[11:00:00], "Etc/UTC")},
            customer_attrs(%{"customer_name" => "Guest #{days}"}),
            notify: false
          )
      end

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/bookings/reservations?filter=confirmed")

      {newest, _} = :binary.match(html, "Guest 4")
      {oldest, _} = :binary.match(html, "Guest 3")
      assert newest < oldest
    end

    test "approving a booking cancelled in another tab says so", %{conn: conn} do
      service = slot_service_fixture(%{"require_approval" => true})
      starts_at = DateTime.new!(Date.add(Date.utc_today(), 2), ~T[10:00:00], "Etc/UTC")

      {:ok, booking} =
        PhoenixKitBookings.Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs(),
          notify: false
        )

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/bookings/reservations?filter=pending")
      {:ok, _} = PhoenixKitBookings.Bookings.cancel_booking(booking, notify: false)

      render_click(view, "confirm", %{"uuid" => booking.uuid})

      assert PhoenixKitBookings.Bookings.get_booking(booking.uuid).status == "cancelled"
    end
  end
end
