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
      service = slot_service_fixture(%{"price" => "12", "seats" => 5})
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

    test "the service's own bookings filling its seats at that time refuse a sign-up" do
      service = slot_service_fixture(%{"seats" => 2})
      event = event_fixture(service, %{"capacity" => 5})

      # Two ordinary bookings take both seats at the event's hour (18:00-19:00).
      {:ok, _} =
        Bookings.create_booking(service, {at(2, 18), at(2, 19)}, customer_attrs(),
          notify: false,
          source: "admin"
        )

      {:ok, _} =
        Bookings.create_booking(service, {at(2, 18), at(2, 19)}, customer_attrs(),
          notify: false,
          source: "admin"
        )

      assert {:error, :at_capacity, _} =
               Bookings.create_event_booking(event, customer_attrs(), notify: false)
    end

    test "the event's own sign-ups count against the service's seats too" do
      service = slot_service_fixture(%{"seats" => 2})
      event = event_fixture(service, %{"capacity" => 5})

      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert {:error, :at_capacity, _} =
               Bookings.create_event_booking(event, customer_attrs(), notify: false)

      # One ordinary booking at that time leaves room for one sign-up only.
      busy = slot_service_fixture(%{"seats" => 2})
      other = event_fixture(busy, %{"capacity" => 5})

      {:ok, _} =
        Bookings.create_booking(busy, {at(2, 18), at(2, 19)}, customer_attrs(), notify: false)

      {:ok, _} = Bookings.create_event_booking(other, customer_attrs(), notify: false)

      assert {:error, :at_capacity, _} =
               Bookings.create_event_booking(other, customer_attrs(), notify: false)
    end

    test "back-to-back bookings that never overlap each other leave a seat" do
      service = slot_service_fixture(%{"seats" => 2})

      event =
        event_fixture(service, %{
          "capacity" => 5,
          "starts_at" => at(2, 17),
          "ends_at" => at(2, 19)
        })

      {:ok, _} =
        Bookings.create_booking(service, {at(2, 17), at(2, 18)}, customer_attrs(),
          notify: false,
          source: "admin"
        )

      {:ok, _} =
        Bookings.create_booking(service, {at(2, 18), at(2, 19)}, customer_attrs(),
          notify: false,
          source: "admin"
        )

      assert {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
    end

    test "an event that ignores the service's capacity sells its seats anyway" do
      service = slot_service_fixture()

      {:ok, _} =
        Bookings.create_booking(service, {at(2, 18), at(2, 19)}, customer_attrs(), notify: false)

      blocked = event_fixture(service)

      assert {:error, :at_capacity, _} =
               Bookings.create_event_booking(blocked, customer_attrs(), notify: false)

      free = event_fixture(service, %{"ignore_service_capacity" => "true"})
      assert Events.get_event(free.uuid).settings["ignore_service_capacity"] == true
      assert {:ok, _} = Bookings.create_event_booking(free, customer_attrs(), notify: false)
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

    test "capacity cannot drop below the seats taken" do
      event = event_fixture(slot_service_fixture(%{"seats" => 5}), %{"capacity" => 2})
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert {:error, cs} = Events.update_event(event, %{"capacity" => 1})
      assert errors_on(cs)[:capacity] == ["is below the 2 seats already booked"]
      assert {:ok, %{capacity: 3}} = Events.update_event(event, %{"capacity" => 3})
    end

    test "rescheduling moves the bookings, mails each customer an updated .ics, and moves the reminder" do
      import Swoosh.TestAssertions

      service = slot_service_fixture(%{"reminder_minutes" => 60})
      event = event_fixture(service)
      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert {:ok, moved} =
               Events.update_event(event, %{"starts_at" => at(3, 9), "ends_at" => at(3, 10)})

      assert moved.starts_at == at(3, 9)
      stored = Bookings.get_booking(booking.uuid)
      assert {stored.starts_at, stored.ends_at} == {at(3, 9), at(3, 10)}

      assert_email_sent(fn email ->
        assert email.subject =~ "Booking moved"
        assert email.text_body =~ "has moved"
        assert [%{filename: "booking.ics", data: ics}] = email.attachments
        assert ics =~ "SEQUENCE:"
        assert ics =~ "DTSTART:" <> Calendar.strftime(at(3, 9), "%Y%m%dT%H%M%SZ")
      end)
    end

    test "moving to another service takes the bookings along and frees the old service" do
      service = slot_service_fixture()
      other = slot_service_fixture()
      event = event_fixture(service)
      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      assert {:ok, %{service_uuid: uuid}} =
               Events.update_event(event, %{"service_uuid" => other.uuid}, notify: false)

      assert uuid == other.uuid
      assert Bookings.get_booking(booking.uuid).service_uuid == other.uuid

      assert {:ok, _} =
               Bookings.create_booking(service, {at(2, 18), at(2, 19)}, customer_attrs(),
                 notify: false
               )
    end

    test "a move must fit all the bookings it brings, and lands only on a timed service" do
      service = slot_service_fixture(%{"seats" => 2})
      event = event_fixture(service, %{"capacity" => 2})
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      # One ordinary booking at the new hour: two moving seats do not fit in two.
      {:ok, _} =
        Bookings.create_booking(service, {at(3, 9), at(3, 10)}, customer_attrs(), notify: false)

      assert {:error, cs} =
               Events.update_event(event, %{"starts_at" => at(3, 9), "ends_at" => at(3, 10)})

      assert errors_on(cs)[:starts_at] == ["the service is fully booked at the new time"]

      hotel = hotel_service_fixture()
      assert {:error, cs} = Events.update_event(event, %{"service_uuid" => hotel.uuid})

      assert errors_on(cs)[:service_uuid] == [
               "must be a minute-based service while the event has bookings"
             ]
    end

    test "moved bookings are re-priced for the new length" do
      service = slot_service_fixture(%{"price" => "30", "price_per" => "hour"})
      event = event_fixture(service, %{"capacity" => 1})
      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      assert Decimal.equal?(booking.total_price, Decimal.new("30.00"))

      {:ok, _} =
        Events.update_event(event, %{"starts_at" => at(3, 9), "ends_at" => at(3, 11)},
          notify: false
        )

      assert Decimal.equal?(Bookings.get_booking(booking.uuid).total_price, Decimal.new("60.00"))
    end

    test "a move is refused while the service is full at the new time; nothing moves" do
      service = slot_service_fixture()
      event = event_fixture(service)
      {:ok, booking} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      {:ok, _} =
        Bookings.create_booking(service, {at(3, 9), at(3, 10)}, customer_attrs(), notify: false)

      assert {:error, cs} =
               Events.update_event(event, %{"starts_at" => at(3, 9), "ends_at" => at(3, 10)})

      assert errors_on(cs)[:starts_at] == ["the service is fully booked at the new time"]
      assert Bookings.get_booking(booking.uuid).starts_at == at(2, 18)
    end

    test "a blank capacity falls back to the service's seats, judged against the seats taken" do
      # Two seats sold on a one-seat service: only an event that ignores the
      # service's capacity gets there.
      event =
        event_fixture(slot_service_fixture(), %{
          "capacity" => 2,
          "ignore_service_capacity" => "true"
        })

      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, _} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      # The fixture service has one seat.
      assert {:error, cs} = Events.update_event(event, %{"capacity" => nil})
      assert errors_on(cs)[:capacity] == ["is below the 2 seats already booked"]
    end

    test "a sign-up through a struct of an event moved to another service is refused" do
      stale = event_fixture(slot_service_fixture())
      {:ok, _} = Events.update_event(stale, %{"service_uuid" => slot_service_fixture().uuid})

      assert {:error, :event_unavailable, _} =
               Bookings.create_event_booking(stale, customer_attrs(), notify: false)
    end

    test "saving a cancelled event finishes an interrupted sweep, sparing later sign-ups" do
      event = event_fixture(slot_service_fixture(%{"seats" => 5}), %{"capacity" => 3})
      {:ok, early} = Bookings.create_event_booking(event, customer_attrs(), notify: false)
      {:ok, later} = Bookings.create_event_booking(event, customer_attrs(), notify: false)

      # The cancellation committed at 12:00 but its sweep never ran; `later`
      # was taken after a reinstatement that has since been undone again.
      stamp = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      repo = PhoenixKit.RepoHelper.repo()

      repo.update_all(from(e in PhoenixKitBookings.Schemas.Event, where: e.uuid == ^event.uuid),
        set: [status: "cancelled", updated_at: stamp]
      )

      repo.update_all(from(b in PhoenixKitBookings.Schemas.Booking, where: b.uuid == ^early.uuid),
        set: [inserted_at: DateTime.add(stamp, -60)]
      )

      repo.update_all(from(b in PhoenixKitBookings.Schemas.Booking, where: b.uuid == ^later.uuid),
        set: [inserted_at: DateTime.add(stamp, 60)]
      )

      assert {:ok, %{status: "cancelled"}} =
               Events.update_event(event, %{"status" => "cancelled"}, notify: false)

      assert Bookings.get_booking(early.uuid).status == "cancelled"
      assert Bookings.get_booking(later.uuid).status == "confirmed"
    end

    test "an update is judged on the stored row, not on a stale struct" do
      stale =
        event_fixture(slot_service_fixture(), %{"starts_at" => at(4, 10), "ends_at" => at(4, 11)})

      {:ok, _} = Events.update_event(stale, %{"starts_at" => at(4, 12), "ends_at" => at(4, 13)})

      # Valid against the stored 12:00-13:00, invalid against the stale 11:00 end.
      assert {:ok, moved} = Events.update_event(stale, %{"starts_at" => at(4, 11)})
      assert moved.starts_at == at(4, 11)
      assert moved.ends_at == at(4, 13)
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
