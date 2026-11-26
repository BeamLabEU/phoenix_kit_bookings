defmodule PhoenixKitBookings.AvailabilityViewTest do
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKitBookings.{AvailabilityView, Bookings, Imports, Services}

  defp at(date, hour), do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  test "a slot service: free, partly booked, booked, closed and past days" do
    service = slot_service_fixture()
    business_hours_rule_fixture(service, %{"start_time" => "09:00:00", "end_time" => "11:00:00"})

    monday = next_weekday(1)
    tuesday = Date.add(monday, 1)
    wednesday = Date.add(monday, 2)
    saturday = Date.add(monday, 5)
    today = Date.add(monday, -1)

    {:ok, _} =
      Bookings.create_booking(service, {at(tuesday, 9), at(tuesday, 10)}, customer_attrs(),
        notify: false
      )

    {:ok, _} =
      Imports.sync_bookings(service, "ical", [
        %{external_id: "1", range: {at(wednesday, 9), at(wednesday, 10)}},
        %{external_id: "2", range: {at(wednesday, 10), at(wednesday, 11)}}
      ])

    statuses =
      AvailabilityView.day_statuses(service, Date.add(monday, -2), saturday,
        today: today,
        tz: "Etc/UTC",
        now: at(today, 0)
      )

    assert statuses[Date.add(monday, -2)] == :past
    assert statuses[monday] == :free
    assert statuses[tuesday] == :partial
    assert statuses[wednesday] == :booked
    assert statuses[saturday] == :closed
  end

  test "pooled seats: a day with some seats taken is partly booked" do
    service = freeform_service_fixture(%{"seats" => 3, "min_duration" => 60})
    day = Date.add(Date.utc_today(), 3)

    {:ok, _} =
      Bookings.create_booking(service, {at(day, 10), at(day, 12)}, customer_attrs(),
        notify: false
      )

    statuses = AvailabilityView.day_statuses(service, day, Date.add(day, 1), tz: "Etc/UTC")
    assert statuses[day] == :partial
    assert statuses[Date.add(day, 1)] == :free
  end

  test "a night service counts seats per date" do
    hotel = hotel_service_fixture(%{"seats" => 2})
    d = Date.add(Date.utc_today(), 4)

    {:ok, _} =
      Bookings.create_booking(hotel, {:dates, d, Date.add(d, 2)}, customer_attrs(), notify: false)

    {:ok, _} =
      Bookings.create_booking(hotel, {:dates, d, Date.add(d, 1)}, customer_attrs(), notify: false)

    statuses = AvailabilityView.day_statuses(hotel, d, Date.add(d, 2))
    assert statuses[d] == :booked
    assert statuses[Date.add(d, 1)] == :partial
    assert statuses[Date.add(d, 2)] == :free
  end

  test "a closed date of a day service reads closed" do
    hotel = hotel_service_fixture()
    d = Date.add(Date.utc_today(), 6)
    {:ok, _} = Services.add_rule(hotel, %{"date" => d, "available" => false})

    assert AvailabilityView.day_statuses(hotel, d, d)[d] == :closed
  end
end
