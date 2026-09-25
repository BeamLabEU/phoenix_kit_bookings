defmodule PhoenixKitBookings.ActivityTest do
  @moduledoc """
  Bookings logs through core's `PhoenixKit.Activity.log/3` under its own
  module key, and the policy layer attributes an action to the scope's
  user.
  """
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitBookings.{Activity, Policy}
  alias PhoenixKitBookings.Test.Repo

  test "an entry is stored under the bookings module key" do
    assert {:ok, %Entry{module: "bookings", action: "bookings.probe", mode: "manual"}} =
             Activity.log("bookings.probe", resource_type: "booking")
  end

  test "a service created through the policy is logged as the scope's user" do
    actor = Ecto.UUID.generate()

    scope = %PhoenixKit.Users.Auth.Scope{
      user: %{uuid: actor, email: "a-#{System.unique_integer([:positive])}@example.com"},
      authenticated?: true,
      cached_roles: [],
      cached_permissions: MapSet.new(["bookings", "bookings.manage_all"])
    }

    {:ok, service} = Policy.create_service(scope, %{"name" => "Probe #{actor}"})

    assert Repo.one(
             from(e in Entry,
               where: e.action == "bookings.service_created" and e.resource_uuid == ^service.uuid,
               select: e.actor_uuid
             )
           ) == actor
  end
end
