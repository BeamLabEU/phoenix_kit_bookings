defmodule PhoenixKitBookings.StaleWritesTest do
  @moduledoc """
  A booking page holds its structs for as long as a visitor keeps it open, so
  every write has to answer for the row as stored, not the struct it was handed.
  """

  use PhoenixKitBookings.DataCase, async: true

  import Swoosh.TestAssertions

  alias PhoenixKitBookings.{Bookings, Services}
  alias PhoenixKitBookings.Schemas.Booking

  defp tomorrow_at(hour) do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp range, do: {tomorrow_at(10), tomorrow_at(11)}

  describe "create_booking/4 answers for the service as stored" do
    test "a service trashed while the visitor typed takes no booking" do
      stale = slot_service_fixture()
      {:ok, _} = Services.trash_service(stale)

      assert {:error, :service_unavailable, _} =
               Bookings.create_booking(stale, range(), customer_attrs())

      assert Bookings.list_bookings(service_uuid: stale.uuid) == []
    end

    test "a service deactivated while the visitor typed takes no booking" do
      stale = slot_service_fixture()
      {:ok, _} = Services.set_status(stale, "inactive")

      assert {:error, :service_unavailable, _} =
               Bookings.create_booking(stale, range(), customer_attrs())
    end

    test "an admin may still book an inactive service" do
      stale = slot_service_fixture()
      {:ok, _} = Services.set_status(stale, "inactive")

      assert {:ok, _} = Bookings.create_booking(stale, range(), customer_attrs(), source: "admin")
    end

    test "approval turned on meanwhile applies to the booking" do
      stale = slot_service_fixture()
      {:ok, _} = Services.update_service(stale, %{"require_approval" => true})

      assert {:ok, %Booking{status: "pending"}} =
               Bookings.create_booking(stale, range(), customer_attrs())
    end

    test "login required turned on meanwhile applies to the booking" do
      stale = slot_service_fixture()
      {:ok, _} = Services.update_service(stale, %{"signup_policy" => "login_required"})

      assert {:error, :login_required, _} =
               Bookings.create_booking(stale, range(), customer_attrs())
    end

    test "a service deleted meanwhile is an answer, not a crash" do
      stale = slot_service_fixture()
      {:ok, _} = Services.delete_service(stale)

      assert {:error, :service_unavailable, _} =
               Bookings.create_booking(stale, range(), customer_attrs())
    end

    test "a provider's service deleted meanwhile is an answer too" do
      stale = slot_service_fixture(%{"provider_uuid" => Ecto.UUID.generate()})
      {:ok, _} = Services.delete_service(stale)

      assert {:error, :service_unavailable, _} =
               Bookings.create_booking(stale, range(), customer_attrs())
    end
  end

  describe "lifecycle writes answer for the booking as stored" do
    test "cancelling twice mails once" do
      service = slot_service_fixture()
      {:ok, booking} = Bookings.create_booking(service, range(), customer_attrs())
      assert_email_sent(subject: "Booking confirmed — #{service.name}")

      {:ok, cancelled} = Bookings.cancel_booking(booking)
      assert_email_sent(subject: "Booking cancelled — #{service.name}")

      assert {:error, :not_cancellable, _} = Bookings.cancel_booking(booking)
      refute_email_sent()

      assert Bookings.get_booking(booking.uuid).cancelled_at == cancelled.cancelled_at
    end

    test "approving what was cancelled meanwhile does not bring it back" do
      service = slot_service_fixture(%{"require_approval" => true})
      {:ok, pending} = Bookings.create_booking(service, range(), customer_attrs())
      {:ok, _} = Bookings.cancel_booking(pending)

      assert {:error, :not_pending, _} = Bookings.confirm_booking(pending)
      assert Bookings.get_booking(pending.uuid).status == "cancelled"
    end

    test "approving twice mails once" do
      service = slot_service_fixture(%{"require_approval" => true})
      {:ok, pending} = Bookings.create_booking(service, range(), customer_attrs())
      assert_email_sent(subject: "Booking request received — #{service.name}")

      {:ok, %Booking{status: "confirmed"}} = Bookings.confirm_booking(pending)
      assert_email_sent(subject: "Booking approved — #{service.name}")

      assert {:error, :not_pending, _} = Bookings.confirm_booking(pending)
      refute_email_sent()
    end

    test "a confirm and a cancel of a booking in the wrong state are errors, not crashes" do
      service = slot_service_fixture()
      {:ok, booking} = Bookings.create_booking(service, range(), customer_attrs())

      assert {:error, :not_pending, _} = Bookings.confirm_booking(booking)
    end

    test "a transition stamps updated_at" do
      service = slot_service_fixture()
      {:ok, booking} = Bookings.create_booking(service, range(), customer_attrs())

      Repo.update_all(from(b in Booking, where: b.uuid == ^booking.uuid),
        set: [updated_at: ~U[2020-01-01 00:00:00Z]]
      )

      {:ok, cancelled} = Bookings.cancel_booking(booking)

      assert DateTime.compare(cancelled.updated_at, ~U[2021-01-01 00:00:00Z]) == :gt
    end
  end

  describe "manage links" do
    @salt "phoenix_kit_bookings.manage"
    @day 24 * 3600

    defp stay(days_ahead, nights) do
      service = hotel_service_fixture()
      starts_on = Date.add(Date.utc_today(), days_ahead)

      {:ok, booking} =
        Bookings.create_booking(
          service,
          {:dates, starts_on, Date.add(starts_on, nights)},
          customer_attrs()
        )

      booking
    end

    defp token_signed_days_ago(booking, days) do
      Phoenix.Token.sign(PhoenixKitBookings.Test.Endpoint, @salt, booking.uuid,
        signed_at: System.system_time(:second) - days * @day
      )
    end

    test "a link mailed long ago still works while the stay is ahead" do
      booking = stay(200, 2)

      assert %Booking{uuid: uuid} =
               booking |> token_signed_days_ago(100) |> Bookings.booking_from_token()

      assert uuid == booking.uuid
    end

    test "a link stops working 90 days after the booking ended" do
      booking = stay(5, 2)
      token = token_signed_days_ago(booking, 200)

      Repo.update_all(from(b in Booking, where: b.uuid == ^booking.uuid),
        set: [
          starts_on: Date.add(Date.utc_today(), -100),
          ends_on: Date.add(Date.utc_today(), -91)
        ]
      )

      assert Bookings.booking_from_token(token) == nil
    end

    test "a link still works for a booking that ended recently" do
      booking = stay(5, 2)
      token = token_signed_days_ago(booking, 30)

      Repo.update_all(from(b in Booking, where: b.uuid == ^booking.uuid),
        set: [
          starts_on: Date.add(Date.utc_today(), -30),
          ends_on: Date.add(Date.utc_today(), -28)
        ]
      )

      assert %Booking{} = Bookings.booking_from_token(token)
    end

    test "a timed booking's link follows its end the same way" do
      service = slot_service_fixture()
      {:ok, booking} = Bookings.create_booking(service, range(), customer_attrs())
      token = token_signed_days_ago(booking, 200)

      assert %Booking{} = Bookings.booking_from_token(token)

      Repo.update_all(from(b in Booking, where: b.uuid == ^booking.uuid),
        set: [
          starts_at: ~U[2020-01-01 10:00:00Z],
          ends_at: ~U[2020-01-01 11:00:00Z]
        ]
      )

      assert Bookings.booking_from_token(token) == nil
    end
  end

  describe "the admin list" do
    test "newest first keeps the latest in view past the limit" do
      service = freeform_service_fixture()

      for days <- 3..5 do
        day = Date.add(Date.utc_today(), days)

        {:ok, _} =
          Bookings.create_booking(
            service,
            {DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
             DateTime.new!(day, ~T[11:00:00], "Etc/UTC")},
            customer_attrs()
          )
      end

      last_day = Date.add(Date.utc_today(), 5)

      assert [%Booking{starts_at: starts_at}] =
               Bookings.list_bookings(service_uuid: service.uuid, limit: 1, order: :desc)

      assert DateTime.to_date(starts_at) == last_day
    end

    test "timed and dated bookings sort together by when they start" do
      slots = slot_service_fixture()
      hotel = hotel_service_fixture()
      early = Date.add(Date.utc_today(), 3)
      late = Date.add(Date.utc_today(), 6)

      {:ok, stay} =
        Bookings.create_booking(hotel, {:dates, early, Date.add(early, 1)}, customer_attrs())

      {:ok, timed} =
        Bookings.create_booking(
          slots,
          {DateTime.new!(late, ~T[10:00:00], "Etc/UTC"),
           DateTime.new!(late, ~T[11:00:00], "Etc/UTC")},
          customer_attrs()
        )

      uuids =
        [service_uuids: [slots.uuid, hotel.uuid]]
        |> Bookings.list_bookings()
        |> Enum.map(& &1.uuid)

      assert uuids == [stay.uuid, timed.uuid]
    end
  end
end
