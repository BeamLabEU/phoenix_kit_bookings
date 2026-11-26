defmodule PhoenixKitBookings.RegularSlotsTest do
  use PhoenixKitBookings.DataCase, async: true

  import Swoosh.TestAssertions

  alias PhoenixKitBookings.{Bookings, RegularSlots}

  # Site frame == UTC in tests (no time_zone setting).
  defp at(date, hour), do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  defp tuesday, do: next_weekday(2)

  setup do
    owner = user_fixture()

    {:ok, service} =
      PhoenixKitBookings.Services.create_service(
        %{"name" => unique_name("Court"), "duration" => 60, "slot_interval" => 60},
        owner_uuid: owner.uuid
      )

    {:ok, slot} =
      RegularSlots.create_slot(service, %{
        "day_of_week" => 2,
        "start_time" => "18:00:00",
        "end_time" => "19:00:00",
        "customer_name" => "Mari",
        "customer_email" => "Mari@Example.com"
      })

    %{service: service, slot: slot, owner: owner}
  end

  test "someone else booking the usual time is accepted, flagged and the owner is told",
       %{service: service, slot: slot, owner: owner} do
    {:ok, booking} =
      Bookings.create_booking(service, {at(tuesday(), 18), at(tuesday(), 19)}, customer_attrs(),
        notify: false
      )

    assert booking.status == "confirmed"

    assert [%{"slot_uuid" => slot_uuid, "holder_name" => "Mari"}] =
             booking.metadata["regular_slot_conflicts"]

    assert slot_uuid == slot.uuid

    assert_email_sent(fn email ->
      assert [{_, to}] = email.to
      assert to == owner.email
      assert email.subject =~ "Regular slot"
    end)
  end

  test "the regular holder (address compared without case) is not flagged", %{service: service} do
    {:ok, booking} =
      Bookings.create_booking(
        service,
        {at(tuesday(), 18), at(tuesday(), 19)},
        customer_attrs(%{"customer_email" => "mari@example.COM"}),
        notify: false
      )

    refute Map.has_key?(booking.metadata, "regular_slot_conflicts")
    refute_email_sent()
  end

  test "the holder's account matches too", %{service: service} do
    holder = user_fixture()

    {:ok, _} =
      RegularSlots.create_slot(service, %{
        "day_of_week" => 2,
        "start_time" => "10:00:00",
        "end_time" => "11:00:00",
        "user_uuid" => holder.uuid
      })

    {:ok, booking} =
      Bookings.create_booking(service, {at(tuesday(), 10), at(tuesday(), 11)}, customer_attrs(),
        user_uuid: holder.uuid,
        notify: false
      )

    refute Map.has_key?(booking.metadata, "regular_slot_conflicts")
  end

  test "another time or weekday is not a conflict", %{service: service} do
    {:ok, other_hour} =
      Bookings.create_booking(service, {at(tuesday(), 19), at(tuesday(), 20)}, customer_attrs(),
        notify: false
      )

    {:ok, other_day} =
      Bookings.create_booking(
        service,
        {at(next_weekday(3), 18), at(next_weekday(3), 19)},
        customer_attrs(),
        notify: false
      )

    refute Map.has_key?(other_hour.metadata, "regular_slot_conflicts")
    refute Map.has_key?(other_day.metadata, "regular_slot_conflicts")
  end

  test "an inactive slot warns nobody", %{service: service, slot: slot} do
    {:ok, _} = RegularSlots.update_slot(slot, %{"active" => false})

    {:ok, booking} =
      Bookings.create_booking(service, {at(tuesday(), 18), at(tuesday(), 19)}, customer_attrs(),
        notify: false
      )

    refute Map.has_key?(booking.metadata, "regular_slot_conflicts")
  end

  test "a whole-day slot of a day service covers every stay touching its weekday" do
    hotel = hotel_service_fixture()

    {:ok, _} =
      RegularSlots.create_slot(hotel, %{"day_of_week" => 2, "customer_email" => "r@x.ee"})

    monday = next_weekday(1)

    assert [_] = RegularSlots.conflicts(hotel.uuid, {:dates, monday, Date.add(monday, 2)}, %{})
    # Monday night only: checkout on Tuesday does not touch it.
    assert [] = RegularSlots.conflicts(hotel.uuid, {:dates, monday, Date.add(monday, 1)}, %{})
  end

  test "a holder is required, and both times or neither", %{service: service} do
    assert {:error, cs} = RegularSlots.create_slot(service, %{"day_of_week" => 1})
    assert errors_on(cs)[:customer_email]

    assert {:error, cs} =
             RegularSlots.create_slot(service, %{
               "day_of_week" => 1,
               "start_time" => "10:00:00",
               "customer_email" => "a@b.ee"
             })

    assert errors_on(cs)[:end_time]
  end

  test "a short range across the fall-back hour still touches a slot in that hour",
       %{service: service} do
    {:ok, sunday} =
      RegularSlots.create_slot(service, %{
        "day_of_week" => 7,
        "start_time" => "03:55:00",
        "end_time" => "03:59:00",
        "customer_email" => "holder@example.com"
      })

    # Europe/Tallinn falls back 04:00 EEST -> 03:00 EET on 2027-10-31: this
    # range runs 03:50 (+03) to 03:10 (+02) on the wall clock.
    range = {~U[2027-10-31 00:50:00Z], ~U[2027-10-31 01:10:00Z]}

    conflicts =
      RegularSlots.conflicts(service.uuid, range, %{email: "other@example.com"}, "Europe/Tallinn")

    assert Enum.any?(conflicts, &(&1.uuid == sunday.uuid))
  end
end
