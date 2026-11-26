defmodule PhoenixKitBookings.EventsTest do
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKitBookings.{Bookings, Events, HostProfiles, Services}

  defp at(days, hour) do
    Date.utc_today() |> Date.add(days) |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp event_fixture(service, attrs \\ %{}) do
    {:ok, event} =
      Events.create_event(
        Map.merge(
          %{
            "service_uuid" => service.uuid,
            "title" => unique_name("Yoga"),
            "starts_at" => at(2, 18),
            "ends_at" => at(2, 19),
            "capacity" => 2
          },
          attrs
        )
      )

    event
  end

  describe "create_event_booking/3" do
    test "books seats up to the event's capacity, then refuses" do
      service = slot_service_fixture(%{"price" => "12"})
      event = event_fixture(service)

      {:ok, one} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _two} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert one.event_uuid == event.uuid
      assert one.starts_at == event.starts_at
      assert Decimal.equal?(one.total_price, Decimal.new("12.00"))

      assert {:error, :at_capacity, _} =
               Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert Bookings.event_seats_taken(event.uuid) == 2
    end

    test "a cancelled seat frees a place" do
      event = event_fixture(slot_service_fixture(), %{"capacity" => 1})
      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _} = Bookings.cancel_booking(booking, notify: false)

      assert {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
    end

    test "the event's own price wins; no capacity means the service's" do
      service = slot_service_fixture(%{"price" => "12", "seats" => 1})
      event = event_fixture(service, %{"capacity" => nil, "price" => "5"})

      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      assert Decimal.equal?(booking.total_price, Decimal.new("5.00"))

      assert {:error, :at_capacity, _} =
               Bookings.create_event_booking(event, customer_attrs(), notify: false)
    end

    test "a cancelled or past event, or an inactive service, takes no sign-ups" do
      service = slot_service_fixture()
      event = event_fixture(service)
      {:ok, cancelled} = Events.cancel_event(event)

      assert {:error, :event_unavailable, _} =
               Bookings.create_event_booking(cancelled, customer_attrs())

      past = event_fixture(service, %{"starts_at" => at(-1, 10), "ends_at" => at(-1, 11)})

      assert {:error, :event_unavailable, _} =
               Bookings.create_event_booking(past, customer_attrs())

      live = event_fixture(service)
      {:ok, _} = Services.set_status(service, "inactive")

      assert {:error, :service_unavailable, _} =
               Bookings.create_event_booking(live, customer_attrs())
    end

    test "a login-required service needs a user" do
      service = slot_service_fixture(%{"signup_policy" => "login_required"})
      event = event_fixture(service)

      assert {:error, :login_required, _} = Bookings.create_event_booking(event, customer_attrs())
    end

    test "event seats occupy the service's own slot" do
      service = slot_service_fixture()
      event = event_fixture(service)
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert {:error, reason, _} =
               Bookings.create_booking(service, {at(2, 18), at(2, 19)}, customer_attrs())

      assert reason in [:overlap, :at_capacity]
    end
  end

  test "cancelling an event cancels its bookings" do
    event = event_fixture(slot_service_fixture())
    {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

    {:ok, cancelled} = Events.cancel_event(event, notify: false)

    assert cancelled.status == "cancelled"
    assert Bookings.get_booking(booking.uuid).status == "cancelled"
  end

  describe "the public schedule" do
    test "lists upcoming public events of active services, soonest first" do
      service = slot_service_fixture()
      later = event_fixture(service, %{"starts_at" => at(5, 10), "ends_at" => at(5, 11)})
      sooner = event_fixture(service)
      _hidden = event_fixture(service, %{"public" => false})
      _past = event_fixture(service, %{"starts_at" => at(-2, 10), "ends_at" => at(-2, 11)})
      cancelled = event_fixture(service)
      {:ok, _} = Events.cancel_event(cancelled)

      inactive = slot_service_fixture()
      _of_inactive = event_fixture(inactive)
      {:ok, _} = Services.set_status(inactive, "inactive")

      assert Enum.map(Events.list_public_upcoming(), & &1.uuid) == [sooner.uuid, later.uuid]
    end

    test "a host's events: the event's own host, or its service's" do
      {:ok, host} = HostProfiles.create_profile(%{"name" => unique_name("Anna")})
      {:ok, other} = HostProfiles.create_profile(%{"name" => unique_name("Olev")})

      service = slot_service_fixture(%{"host_profile_uuid" => host.uuid})
      by_service = event_fixture(service)
      by_other = event_fixture(service, %{"host_profile_uuid" => other.uuid})

      plain = slot_service_fixture()
      by_event = event_fixture(plain, %{"host_profile_uuid" => host.uuid})

      uuids = Enum.map(Events.list_public_upcoming(host_profile_uuid: host.uuid), & &1.uuid)

      assert by_service.uuid in uuids
      assert by_event.uuid in uuids
      refute by_other.uuid in uuids
    end

    test "events need an end after the start" do
      assert {:error, cs} =
               Events.create_event(%{
                 "service_uuid" => slot_service_fixture().uuid,
                 "title" => "x",
                 "starts_at" => at(2, 10),
                 "ends_at" => at(2, 9)
               })

      assert errors_on(cs)[:ends_at]
    end
  end

  test "host profiles get a unique slug and only active ones are public" do
    {:ok, a} = HostProfiles.create_profile(%{"name" => "Kristi Tamm"})
    {:ok, b} = HostProfiles.create_profile(%{"name" => "Kristi Tamm"})
    {:ok, _} = HostProfiles.update_profile(b, %{"status" => "inactive"})

    assert a.slug == "kristi-tamm"
    assert b.slug != a.slug
    assert HostProfiles.get_public_profile_by_slug(a.slug).uuid == a.uuid
    assert HostProfiles.get_public_profile_by_slug(b.slug) == nil
  end
end
