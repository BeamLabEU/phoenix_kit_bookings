defmodule PhoenixKitBookings.Web.AdminLiveTest do
  use PhoenixKitBookings.LiveCase, async: true

  alias Ecto.Adapters.SQL
  alias PhoenixKitBookings.{Bookings, Services}
  alias PhoenixKitBookings.Schemas.Service
  alias PhoenixKitBookings.Test.Repo

  defp admin_conn(conn), do: put_test_scope(conn, fake_scope())

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
      assert_redirect(view, "/en/admin/bookings/services/#{service.uuid}/edit")
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
      assert_redirect(view, "/en/admin/bookings/services/#{service.uuid}/edit")
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

      assert {:error, {:live_redirect, %{to: "/en/admin"}}} =
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
end
