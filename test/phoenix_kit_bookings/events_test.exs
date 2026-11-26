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

  describe "update_event/3 with bookings" do
    test "a status change to cancelled cancels the bookings too" do
      event = event_fixture(slot_service_fixture())
      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      {:ok, updated} =
        Events.update_event(event, %{"status" => "cancelled", "title" => "Off"}, notify: false)

      assert updated.status == "cancelled"
      assert updated.title == "Off"
      assert Bookings.get_booking(booking.uuid).status == "cancelled"
    end

    test "capacity cannot drop below the seats taken; the service cannot change" do
      event = event_fixture(slot_service_fixture(), %{"capacity" => 2})
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert {:error, cs} = Events.update_event(event, %{"capacity" => 1})
      assert errors_on(cs)[:capacity] == ["is below the 2 seats already booked"]
      assert {:ok, %{capacity: 3}} = Events.update_event(event, %{"capacity" => 3})

      other = slot_service_fixture()
      assert {:error, cs} = Events.update_event(event, %{"service_uuid" => other.uuid})
      assert errors_on(cs)[:service_uuid] == ["cannot change while the event has bookings"]
      assert Events.get_event(event.uuid).service_uuid == event.service_uuid
    end

    test "an event without bookings can move" do
      event = event_fixture(slot_service_fixture())
      other = slot_service_fixture()

      assert {:ok, %{service_uuid: uuid}} =
               Events.update_event(event, %{"service_uuid" => other.uuid})

      assert uuid == other.uuid
    end

    test "a sign-up through a struct from before a reschedule takes the new times and price" do
      service = slot_service_fixture(%{"price" => "30", "price_per" => "hour"})
      stale = event_fixture(service, %{"starts_at" => at(3, 10), "ends_at" => at(3, 11)})
      {:ok, _} = Events.update_event(stale, %{"starts_at" => at(3, 12), "ends_at" => at(3, 14)})

      {:ok, booking} = Bookings.create_event_booking(stale, customer_attrs(), notify: false)

      assert booking.starts_at == at(3, 12)
      assert booking.ends_at == at(3, 14)
      assert Decimal.equal?(booking.total_price, Decimal.new("60.00"))
    end
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
