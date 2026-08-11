defmodule PhoenixKitBookings.FeaturesTest do
  use PhoenixKitBookings.DataCase, async: true

  import Swoosh.TestAssertions

  alias PhoenixKitBookings.{Bookings, ICS, Pricing, Services}
  alias PhoenixKitBookings.Schemas.Booking
  alias PhoenixKitBookings.Workers.ReminderWorker

  defp tomorrow_at(hour) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp future_date(days), do: Date.add(Date.utc_today(), days)

  describe "cancellation windows" do
    test "cancel_notice gates the customer, not the admin" do
      service = slot_service_fixture(%{"cancel_notice" => 48 * 60})

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      # Starts ~tomorrow, window is 48h — customer is too late, admin isn't.
      refute Bookings.cancellable_by_customer?(booking, service)
      assert {:ok, _} = Bookings.cancel_booking(booking)
    end

    test "zero notice means cancellable until the start" do
      service = slot_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert Bookings.cancellable_by_customer?(booking, service)
    end

    test "day-mode windows count in days" do
      service = hotel_service_fixture(%{"cancel_notice" => 2 * 1440})

      {:ok, close} =
        Bookings.create_booking(
          service,
          {:dates, future_date(1), future_date(3)},
          customer_attrs()
        )

      {:ok, far} =
        Bookings.create_booking(
          service,
          {:dates, future_date(10), future_date(12)},
          customer_attrs()
        )

      refute Bookings.cancellable_by_customer?(close, service)
      assert Bookings.cancellable_by_customer?(far, service)
    end
  end

  describe "named units" do
    test "capacity follows the active-unit count and bookings get assigned" do
      service = hotel_service_fixture(%{"seats" => 99})
      {:ok, _} = Services.add_unit(service, %{"name" => "Room 101"})
      {:ok, u2} = Services.add_unit(service, %{"name" => "Room 102"})

      assert Services.effective_seats(service) == 2

      range = {:dates, future_date(7), future_date(9)}

      {:ok, b1} = Bookings.create_booking(service, range, customer_attrs())
      {:ok, b2} = Bookings.create_booking(service, range, customer_attrs())

      # Two units → two bookings, distinct assignments, then full despite seats=99.
      assert b1.unit_uuid != nil
      assert b2.unit_uuid != nil
      assert b1.unit_uuid != b2.unit_uuid
      assert {:error, :at_capacity, _} = Bookings.create_booking(service, range, customer_attrs())

      # Deactivating a unit shrinks capacity.
      {:ok, _} = Services.set_unit_active(u2, false)
      assert Services.effective_seats(service) == 1
    end

    test "unit frees up when its booking is cancelled" do
      service = slot_service_fixture()
      {:ok, unit} = Services.add_unit(service, %{"name" => "Chair 1"})
      range = {tomorrow_at(10), tomorrow_at(11)}

      {:ok, booking} = Bookings.create_booking(service, range, customer_attrs())
      assert booking.unit_uuid == unit.uuid
      assert {:error, _, _} = Bookings.create_booking(service, range, customer_attrs())

      {:ok, _} = Bookings.cancel_booking(booking)
      {:ok, again} = Bookings.create_booking(service, range, customer_attrs())
      assert again.unit_uuid == unit.uuid
    end
  end

  describe "provider conflicts" do
    test "the same provider's bookings block across services" do
      provider_uuid = Ecto.UUID.generate()

      massage = slot_service_fixture(%{"provider_uuid" => provider_uuid})
      consult = slot_service_fixture(%{"provider_uuid" => provider_uuid, "seats" => 5})
      other = slot_service_fixture(%{"seats" => 5})

      range = {tomorrow_at(10), tomorrow_at(11)}

      {:ok, _} = Bookings.create_booking(massage, range, customer_attrs())

      # Same provider, different service, plenty of seats — still blocked.
      assert {:error, :overlap, _} = Bookings.create_booking(consult, range, customer_attrs())

      # A provider-less service is unaffected.
      assert {:ok, _} = Bookings.create_booking(other, range, customer_attrs())

      # The provider is free at another time.
      assert {:ok, _} =
               Bookings.create_booking(
                 consult,
                 {tomorrow_at(11), tomorrow_at(12)},
                 customer_attrs()
               )
    end
  end

  describe "pricing" do
    test "flat, hourly, and nightly totals" do
      flat = slot_service_fixture(%{"price" => "50.00"})
      hourly = freeform_service_fixture(%{"price" => "12.00", "price_per" => "hour"})
      nightly = hotel_service_fixture(%{"price" => "80.00", "price_per" => "night"})

      {:ok, b1} =
        Bookings.create_booking(flat, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert Decimal.equal?(b1.total_price, Decimal.new("50.00"))
      assert b1.currency == "EUR"

      {:ok, b2} =
        Bookings.create_booking(hourly, {tomorrow_at(6), tomorrow_at(8)}, customer_attrs())

      assert Decimal.equal?(b2.total_price, Decimal.new("24.00"))

      {:ok, b3} =
        Bookings.create_booking(
          nightly,
          {:dates, future_date(7), future_date(10)},
          customer_attrs()
        )

      assert Decimal.equal?(b3.total_price, Decimal.new("240.00"))
    end

    test "unpriced services carry no total" do
      service = slot_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert booking.total_price == nil
      assert booking.currency == nil
      assert Pricing.tag(service) == nil
    end

    test "fractional hours price proportionally" do
      service = freeform_service_fixture(%{"price" => "10.00", "price_per" => "hour"})
      ends = DateTime.add(tomorrow_at(6), 90 * 60, :second)

      {:ok, booking} = Bookings.create_booking(service, {tomorrow_at(6), ends}, customer_attrs())
      assert Decimal.equal?(booking.total_price, Decimal.new("15.00"))
    end
  end

  describe "holds" do
    test "an unexpired hold blocks rivals but not its owner" do
      service = slot_service_fixture()
      range = {tomorrow_at(10), tomorrow_at(11)}

      {:ok, hold} = Bookings.create_hold(service, range)

      # A rival without the hold loses the slot.
      assert {:error, :overlap, _} = Bookings.create_booking(service, range, customer_attrs())

      # The hold's owner books straight through it and consumes it.
      assert {:ok, _} =
               Bookings.create_booking(service, range, customer_attrs(), hold_uuid: hold.uuid)

      refute Enum.any?(
               Bookings.list_occupancy(service.uuid, {tomorrow_at(9), tomorrow_at(12)}),
               &(&1.uuid == hold.uuid)
             )
    end

    test "expired holds don't count and get pruned" do
      service = slot_service_fixture()
      range = {tomorrow_at(10), tomorrow_at(11)}

      {:ok, _hold} = Bookings.create_hold(service, range, ttl_seconds: -60)

      assert {:ok, _} = Bookings.create_booking(service, range, customer_attrs())
    end

    test "release_hold is idempotent and cast-safe" do
      service = slot_service_fixture()
      {:ok, hold} = Bookings.create_hold(service, {tomorrow_at(10), tomorrow_at(11)})

      assert :ok = Bookings.release_hold(hold.uuid)
      assert :ok = Bookings.release_hold(hold.uuid)
      assert :ok = Bookings.release_hold("not-a-uuid")
      assert :ok = Bookings.release_hold(nil)
    end
  end

  describe "waitlist" do
    test "joining is idempotent per email+date and cancellation notifies" do
      service = slot_service_fixture()
      range = {tomorrow_at(10), tomorrow_at(11)}
      {:ok, booking} = Bookings.create_booking(service, range, customer_attrs())

      date = Date.add(Date.utc_today(), 1)

      attrs = %{
        "date" => Date.to_iso8601(date),
        "customer_name" => "Waiting Guest",
        "customer_email" => "waiting@example.com"
      }

      {:ok, entry} = Bookings.join_waitlist(service, attrs)
      {:ok, same} = Bookings.join_waitlist(service, attrs)
      assert entry.uuid == same.uuid

      assert Bookings.waitlist_counts()[service.uuid] == 1

      # Consume the create-confirmation, then cancel (cancellation email
      # precedes the waitlist notification).
      assert_email_sent(fn email -> assert email.subject =~ "Booking confirmed" end)
      {:ok, _} = Bookings.cancel_booking(booking)
      assert_email_sent(fn email -> assert email.subject =~ "Booking cancelled" end)

      assert_email_sent(fn email ->
        assert email.subject =~ "A spot opened up"
        assert Enum.any?(email.to, fn {_name, addr} -> addr == "waiting@example.com" end)
      end)

      assert [%{status: "notified"}] = Bookings.list_waitlist(service.uuid)
      assert Bookings.waitlist_counts()[service.uuid] == nil
    end

    test "rejects garbage waitlist input" do
      service = slot_service_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bookings.join_waitlist(service, %{"customer_email" => "nope"})
    end
  end

  describe "emails" do
    test "confirmation email with ICS goes out on create" do
      service = slot_service_fixture()

      {:ok, _booking} =
        Bookings.create_booking(
          service,
          {tomorrow_at(10), tomorrow_at(11)},
          customer_attrs(%{"customer_email" => "confirm-me@example.com"})
        )

      assert_email_sent(fn email ->
        assert email.subject =~ "Booking confirmed"
        assert Enum.any?(email.to, fn {_n, addr} -> addr == "confirm-me@example.com" end)
        assert [%Swoosh.Attachment{filename: "booking.ics"}] = email.attachments
      end)
    end

    test "pending flow: request email, then approval email on confirm" do
      service = slot_service_fixture(%{"require_approval" => true})

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert_email_sent(fn email -> assert email.subject =~ "request received" end)

      {:ok, _} = Bookings.confirm_booking(booking)
      assert_email_sent(fn email -> assert email.subject =~ "Booking approved" end)
    end

    test "cancellation email on cancel" do
      service = slot_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert_email_sent(fn email -> assert email.subject =~ "Booking confirmed" end)
      {:ok, _} = Bookings.cancel_booking(booking)
      assert_email_sent(fn email -> assert email.subject =~ "Booking cancelled" end)
    end
  end

  describe "ICS" do
    test "timed and day bookings render valid skeletons" do
      timed = %Booking{
        uuid: Ecto.UUID.generate(),
        status: "confirmed",
        starts_at: ~U[2030-06-10 10:00:00Z],
        ends_at: ~U[2030-06-10 11:00:00Z]
      }

      dated = %Booking{
        uuid: Ecto.UUID.generate(),
        status: "confirmed",
        starts_on: ~D[2030-06-10],
        ends_on: ~D[2030-06-12]
      }

      service = %PhoenixKitBookings.Schemas.Service{name: "Test; Room, Deluxe"}

      ics = ICS.booking_ics(timed, service, "https://example.com/manage")
      assert ics =~ "BEGIN:VCALENDAR"
      assert ics =~ "DTSTART:20300610T100000Z"
      assert ics =~ "SUMMARY:Test\\; Room\\, Deluxe"

      ics2 = ICS.booking_ics(dated, service, "https://example.com/manage")
      assert ics2 =~ "DTSTART;VALUE=DATE:20300610"
      assert ics2 =~ "DTEND;VALUE=DATE:20300612"
    end
  end

  describe "reminder worker" do
    test "perform sends for active bookings and skips cancelled ones" do
      service = slot_service_fixture(%{"reminder_minutes" => 60})

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert_email_sent(fn email -> assert email.subject =~ "Booking confirmed" end)
      assert :ok = ReminderWorker.perform(%Oban.Job{args: %{"booking_uuid" => booking.uuid}})
      assert_email_sent(fn email -> assert email.subject =~ "Reminder" end)

      {:ok, cancelled} = Bookings.cancel_booking(booking)
      assert :ok = ReminderWorker.perform(%Oban.Job{args: %{"booking_uuid" => cancelled.uuid}})

      assert :ok =
               ReminderWorker.perform(%Oban.Job{args: %{"booking_uuid" => Ecto.UUID.generate()}})
    end
  end
end
