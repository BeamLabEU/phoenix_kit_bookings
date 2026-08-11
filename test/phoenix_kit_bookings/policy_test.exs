defmodule PhoenixKitBookings.PolicyTest do
  use PhoenixKitBookings.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Settings
  alias PhoenixKitBookings.{Policy, Services}
  alias PhoenixKitBookings.Test.Repo

  # Real Scope structs, mirroring LiveCase.fake_scope/1 (DataCase doesn't
  # import it — LiveCase is endpoint-flavored).
  defp scope(permissions, user_uuid \\ Ecto.UUID.generate()) do
    %PhoenixKit.Users.Auth.Scope{
      user: %{uuid: user_uuid, email: "u-#{System.unique_integer([:positive])}@example.com"},
      authenticated?: true,
      cached_roles: MapSet.new([:user]),
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp admin_scope, do: scope(["bookings", "bookings.manage_all"])
  defp user_scope(user_uuid \\ Ecto.UUID.generate()), do: scope(["bookings"], user_uuid)

  defp create_real_user do
    {:ok, %{rows: [[uuid]]}} =
      SQL.query(
        Repo,
        "INSERT INTO phoenix_kit_users (email, hashed_password, inserted_at, updated_at) " <>
          "VALUES ($1, 'x', NOW(), NOW()) RETURNING uuid",
        ["owner-#{System.unique_integer([:positive])}@example.com"]
      )

    Ecto.UUID.load!(uuid)
  end

  defp enable_self_service(max) do
    Settings.update_boolean_setting_with_module(
      "bookings_user_services_enabled",
      true,
      "bookings"
    )

    Settings.update_setting_with_module(
      "bookings_max_services_per_user",
      Integer.to_string(max),
      "bookings"
    )
  end

  describe "manage_all? / can_manage?" do
    test "site-wide managers manage everything; users only their own" do
      user_uuid = create_real_user()
      site_service = slot_service_fixture()

      {:ok, owned} =
        Services.create_service(%{"name" => unique_name("Mine")}, owner_uuid: user_uuid)

      admin = admin_scope()
      user = user_scope(user_uuid)
      stranger = user_scope()

      assert Policy.manage_all?(admin)
      refute Policy.manage_all?(user)

      assert Policy.can_manage?(admin, site_service)
      assert Policy.can_manage?(admin, owned)

      refute Policy.can_manage?(user, site_service)
      assert Policy.can_manage?(user, owned)
      refute Policy.can_manage?(stranger, owned)
    end
  end

  describe "visible_services/2" do
    test "scopes listings by ownership" do
      user_uuid = create_real_user()
      site_service = slot_service_fixture()

      {:ok, owned} =
        Services.create_service(%{"name" => unique_name("Mine")}, owner_uuid: user_uuid)

      admin_visible = Policy.visible_services(admin_scope()) |> Enum.map(& &1.uuid)
      assert site_service.uuid in admin_visible
      assert owned.uuid in admin_visible

      user_visible = Policy.visible_services(user_scope(user_uuid)) |> Enum.map(& &1.uuid)
      assert user_visible == [owned.uuid]
    end
  end

  describe "can_create? and the self-service settings" do
    test "self-service is OFF by default for base-permission users" do
      refute Policy.user_services_enabled?()
      refute Policy.can_create?(user_scope())
      assert Policy.can_create?(admin_scope())
    end

    test "enabling self-service allows creation up to the cap" do
      enable_self_service(1)
      user_uuid = create_real_user()
      user = user_scope(user_uuid)

      assert Policy.can_create?(user)

      {:ok, service} = Policy.create_service(user, %{"name" => unique_name("My studio")})
      assert service.owner_uuid == user_uuid

      # Cap of one reached.
      refute Policy.can_create?(user)
      assert {:error, :not_allowed} = Policy.create_service(user, %{"name" => unique_name("Two")})

      # Trashing the service frees the cap slot.
      {:ok, _} = Policy.trash_service(user, service)
      assert Policy.can_create?(user)
    end

    test "cap 0 means unlimited" do
      enable_self_service(0)
      user_uuid = create_real_user()
      user = user_scope(user_uuid)

      {:ok, _} = Policy.create_service(user, %{"name" => unique_name("One")})
      {:ok, _} = Policy.create_service(user, %{"name" => unique_name("Two")})
      assert Policy.can_create?(user)
    end

    test "admins create SITE services (no owner) regardless of settings" do
      {:ok, service} = Policy.create_service(admin_scope(), %{"name" => unique_name("Site")})
      assert service.owner_uuid == nil
    end
  end

  describe "authorized mutations" do
    test "a user cannot mutate a service they don't own" do
      user_uuid = create_real_user()
      site_service = slot_service_fixture()
      user = user_scope(user_uuid)

      assert {:error, :not_allowed} =
               Policy.update_service(user, site_service, %{"name" => "Hijack"})

      assert {:error, :not_allowed} = Policy.trash_service(user, site_service)

      assert {:error, :not_allowed} =
               Policy.add_rule(user, site_service, %{"days_of_week" => [1]})
    end

    test "booking lifecycle authorizes against the service owner" do
      user_uuid = create_real_user()
      enable_self_service(1)
      user = user_scope(user_uuid)

      {:ok, service} = Policy.create_service(user, %{"name" => unique_name("My studio")})

      starts_at =
        Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

      {:ok, booking} =
        PhoenixKitBookings.Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs()
        )

      # A stranger with only the base permission cannot touch it.
      assert {:error, :not_allowed} = Policy.cancel_booking(user_scope(), booking)

      # The owner and site-wide admins can.
      assert {:ok, _} = Policy.cancel_booking(user, booking)
    end
  end
end
