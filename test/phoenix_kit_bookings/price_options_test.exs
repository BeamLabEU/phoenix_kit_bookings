defmodule PhoenixKitBookings.PriceOptionsTest do
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKit.Users.Roles
  alias PhoenixKitBookings.{Bookings, PriceOptions}
  alias PhoenixKitBookings.Schemas.PriceOption

  defp tomorrow_at(hour) do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp priced_service(attrs \\ %{}) do
    slot_service_fixture(Map.merge(%{"price" => "50", "price_per" => "booking"}, attrs))
  end

  defp option(service, attrs) do
    {:ok, option} =
      PriceOptions.create_option(service, Map.merge(%{"name" => "Solo", "price" => "30"}, attrs))

    option
  end

  describe "entitled?/2" do
    test "everyone: guests and users alike" do
      service = priced_service()
      opt = option(service, %{"entitlement" => "everyone"})

      assert PriceOptions.entitled?(opt, nil)
      assert PriceOptions.entitled?(opt, user_fixture())
    end

    test "users: only the listed accounts, never a guest" do
      service = priced_service()
      client = user_fixture()
      other = user_fixture()
      opt = option(service, %{"entitlement" => "users", "user_uuids" => [client.uuid]})

      assert PriceOptions.entitled?(opt, client)
      assert PriceOptions.entitled?(opt, client.uuid)
      refute PriceOptions.entitled?(opt, other)
      refute PriceOptions.entitled?(opt, nil)
    end

    test "flag: a set custom field entitles, an absent or false one does not" do
      service = priced_service()
      opt = option(service, %{"entitlement" => "flag", "flag_key" => "member"})

      assert PriceOptions.entitled?(opt, user_fixture(%{custom_fields: %{"member" => true}}))
      assert PriceOptions.entitled?(opt, user_fixture(%{custom_fields: %{"member" => "gold"}}))
      refute PriceOptions.entitled?(opt, user_fixture(%{custom_fields: %{"member" => false}}))
      refute PriceOptions.entitled?(opt, user_fixture())
    end

    test "role: holders of the core role" do
      service = priced_service()
      role_name = "Trainee #{System.unique_integer([:positive])}"
      {:ok, _role} = Roles.create_role(%{name: role_name})
      holder = user_fixture()
      {:ok, _} = Roles.assign_role(holder, role_name)
      opt = option(service, %{"entitlement" => "role", "role_name" => role_name})

      assert PriceOptions.entitled?(opt, holder)
      refute PriceOptions.entitled?(opt, user_fixture())
    end

    test "a deactivated account is entitled to nothing restricted" do
      service = priced_service()
      user = user_fixture(%{is_active: false})
      opt = option(service, %{"entitlement" => "users", "user_uuids" => [user.uuid]})

      refute PriceOptions.entitled?(opt, user)
    end
  end

  test "a restricted option needs its target" do
    service = priced_service()

    assert {:error, changeset} =
             PriceOptions.create_option(service, %{
               "name" => "x",
               "price" => "1",
               "entitlement" => "role"
             })

    assert errors_on(changeset)[:role_name]
  end

  test "a price the NUMERIC(12,2) column cannot hold is a validation error, not a raise" do
    service = priced_service()

    assert {:error, changeset} =
             PriceOptions.create_option(service, %{"name" => "x", "price" => "10000000000"})

    assert errors_on(changeset)[:price]

    # Rounds to 10000000000.00 in the column.
    assert {:error, changeset} =
             PriceOptions.create_option(service, %{"name" => "z", "price" => "9999999999.995"})

    assert errors_on(changeset)[:price]

    assert {:ok, _} =
             PriceOptions.create_option(service, %{"name" => "y", "price" => "9999999999.99"})

    starts_at = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    assert {:error, changeset} =
             PhoenixKitBookings.Events.create_event(%{
               "service_uuid" => service.uuid,
               "title" => "Gala",
               "starts_at" => starts_at,
               "ends_at" => DateTime.add(starts_at, 3600),
               "price" => "10000000000"
             })

    assert errors_on(changeset)[:price]
  end

  test "entitled_options/2 lists only active options the customer may use" do
    service = priced_service()
    client = user_fixture()
    open = option(service, %{"name" => "Open", "entitlement" => "everyone"})

    mine =
      option(service, %{"name" => "Mine", "entitlement" => "users", "user_uuids" => [client.uuid]})

    off = option(service, %{"name" => "Off", "entitlement" => "everyone", "active" => false})

    guest_view = Enum.map(PriceOptions.entitled_options(service, nil), & &1.uuid)
    client_view = Enum.map(PriceOptions.entitled_options(service, client), & &1.uuid)

    assert guest_view == [open.uuid]
    assert Enum.sort(client_view) == Enum.sort([open.uuid, mine.uuid])
    refute off.uuid in client_view
  end

  describe "create_booking/4 with a price option" do
    test "an entitled customer books at the option's rate" do
      service = priced_service()
      client = user_fixture()
      opt = option(service, %{"entitlement" => "users", "user_uuids" => [client.uuid]})

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs(),
          user_uuid: client.uuid,
          price_option_uuid: opt.uuid
        )

      assert booking.price_option_uuid == opt.uuid
      assert Decimal.equal?(booking.total_price, Decimal.new("30.00"))
    end

    test "the option's per-hour rate prices the length" do
      service = priced_service()
      opt = option(service, %{"price" => "20", "price_per" => "hour"})

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs(),
          price_option_uuid: opt.uuid
        )

      assert Decimal.equal?(booking.total_price, Decimal.new("20.00"))
    end

    test "a customer who is not entitled is refused and nothing is booked" do
      service = priced_service()
      opt = option(service, %{"entitlement" => "users", "user_uuids" => [user_fixture().uuid]})

      assert {:error, :price_option_unavailable, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(10), tomorrow_at(11)},
                 customer_attrs(),
                 user_uuid: user_fixture().uuid,
                 price_option_uuid: opt.uuid
               )

      assert Bookings.list_bookings(service_uuid: service.uuid) == []
    end

    test "another service's option, an inactive one or a forged id is refused" do
      service = priced_service()
      foreign = option(priced_service(), %{})
      inactive = option(service, %{"active" => false})

      for uuid <- [foreign.uuid, inactive.uuid, "not-a-uuid"] do
        assert {:error, :price_option_unavailable, _} =
                 Bookings.create_booking(
                   service,
                   {tomorrow_at(10), tomorrow_at(11)},
                   customer_attrs(),
                   price_option_uuid: uuid
                 )
      end
    end

    test "the admin may book any active option of the service for a customer" do
      service = priced_service()
      opt = option(service, %{"entitlement" => "users", "user_uuids" => [user_fixture().uuid]})

      assert {:ok, %{price_option_uuid: uuid}} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(10), tomorrow_at(11)},
                 customer_attrs(),
                 source: "admin",
                 price_option_uuid: opt.uuid
               )

      assert uuid == opt.uuid
    end

    test "a blank option is the standard price" do
      service = priced_service()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs(),
          price_option_uuid: ""
        )

      assert booking.price_option_uuid == nil
      assert Decimal.equal?(booking.total_price, Decimal.new("50.00"))
    end
  end

  test "deleting an option keeps the bookings made at it" do
    service = priced_service()
    opt = option(service, %{})

    {:ok, booking} =
      Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs(),
        price_option_uuid: opt.uuid
      )

    {:ok, %PriceOption{}} = PriceOptions.delete_option(opt)
    reloaded = Bookings.get_booking(booking.uuid)

    assert reloaded.price_option_uuid == nil
    assert Decimal.equal?(reloaded.total_price, Decimal.new("30.00"))
  end
end
