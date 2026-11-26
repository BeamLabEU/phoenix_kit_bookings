defmodule PhoenixKitBookings.ImportsTest do
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKitBookings.{Bookings, Imports, Services}
  alias PhoenixKitBookings.Schemas.Booking

  defp at(days, hour) do
    Date.utc_today() |> Date.add(days) |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp entry(id, days, from, until, extra \\ %{}) do
    Map.merge(%{external_id: id, range: {at(days, from), at(days, until)}}, extra)
  end

  describe "sync_bookings/4" do
    test "inserts, updates and removes only its own source's rows" do
      service = slot_service_fixture(%{"seats" => 5})

      {:ok, own} =
        Bookings.create_booking(service, {at(1, 9), at(1, 10)}, customer_attrs(), notify: false)

      {:ok, _} =
        Imports.sync_bookings(service, "other", [entry("x", 1, 14, 15)])

      assert {:ok, %{inserted: 2, updated: 0, deleted: 0}} =
               Imports.sync_bookings(service, "ical", [
                 entry("a", 1, 10, 11, %{customer_name: "Busy"}),
                 entry("b", 2, 10, 11)
               ])

      # Re-sync: "a" moved, "b" gone, "c" new.
      assert {:ok, %{inserted: 1, updated: 1, deleted: 1}} =
               Imports.sync_bookings(service, "ical", [
                 entry("a", 1, 12, 13),
                 entry("c", 3, 10, 11)
               ])

      imported = Imports.list_imported_bookings(service.uuid, "ical")
      assert Enum.map(imported, & &1.external_id) |> Enum.sort() == ["a", "c"]
      assert %Booking{starts_at: starts_at} = Enum.find(imported, &(&1.external_id == "a"))
      assert starts_at == at(1, 12)

      # The owner's booking and the other source are untouched.
      assert Bookings.get_booking(own.uuid).status == "confirmed"
      assert [%{external_id: "x"}] = Imports.list_imported_bookings(service.uuid, "other")
    end

    test "an unchanged re-sync writes nothing" do
      service = slot_service_fixture()
      entries = [entry("a", 1, 10, 11)]

      {:ok, _} = Imports.sync_bookings(service, "ical", entries)

      assert {:ok, %{inserted: 0, updated: 0, deleted: 0}} =
               Imports.sync_bookings(service, "ical", entries)
    end

    test "imported rows need no customer, skip validation and count toward capacity" do
      service = slot_service_fixture()
      business_hours_rule_fixture(service)

      # Outside the opening hours and on a closed day: a fact from outside.
      {:ok, _} =
        Imports.sync_bookings(service, "ical", [
          entry("night", 1, 2, 3),
          entry("busy", 1, 10, 11)
        ])

      [busy | _] = Imports.list_imported_bookings(service.uuid)
      assert busy.source == "import"
      assert busy.customer_email == nil

      assert {:error, reason, _} =
               Bookings.create_booking(service, {at(1, 10), at(1, 11)}, customer_attrs())

      assert reason in [:overlap, :at_capacity, :outside_availability]
    end

    test "a day service takes date ranges" do
      hotel = hotel_service_fixture()
      d = Date.add(Date.utc_today(), 5)

      {:ok, %{inserted: 1}} =
        Imports.sync_bookings(hotel, "smartbron", [
          %{external_id: "1", range: {:dates, d, Date.add(d, 2)}}
        ])

      assert [%{starts_on: ^d}] = Imports.list_imported_bookings(hotel.uuid)
    end

    test "an empty list removes every row of that source" do
      service = slot_service_fixture()
      {:ok, _} = Imports.sync_bookings(service, "ical", [entry("a", 1, 10, 11)])
      assert {:ok, %{deleted: 1}} = Imports.sync_bookings(service, "ical", [])
      assert Imports.list_imported_bookings(service.uuid) == []
    end

    test "a struct whose unit changed since the entries were shaped writes nothing" do
      service = slot_service_fixture()
      {:ok, _} = Imports.sync_bookings(service, "ical", [entry("a", 1, 10, 11)])

      stale = %{service | time_unit: "day"}

      assert {:error, :service_changed} =
               Imports.sync_bookings(stale, "ical", [
                 %{
                   external_id: "b",
                   range: {:dates, Date.utc_today(), Date.add(Date.utc_today(), 1)}
                 }
               ])

      assert [%{external_id: "a"}] = Imports.list_imported_bookings(service.uuid)
    end

    test "a list read before the one last applied is refused and changes nothing" do
      service = slot_service_fixture()
      t1 = ~U[2026-11-26 10:00:00.000000Z]
      t2 = DateTime.add(t1, 5)

      {:ok, %{inserted: 1}} =
        Imports.sync_bookings(service, "ical", [entry("new", 1, 10, 11)], fetched_at: t2)

      assert {:error, :stale_result} =
               Imports.sync_bookings(service, "ical", [], fetched_at: t1)

      assert [%{external_id: "new"}] = Imports.list_imported_bookings(service.uuid)

      # Another source, or the rules of this one, keep their own clock.
      assert {:ok, _} = Imports.sync_bookings(service, "other", [], fetched_at: t1)
      assert {:ok, _} = Imports.sync_rules(service, "ical", [], fetched_at: t1)

      assert {:ok, %{deleted: 1}} =
               Imports.sync_bookings(service, "ical", [], fetched_at: DateTime.add(t2, 1))
    end

    test "a bad entry writes nothing at all" do
      service = slot_service_fixture()
      {:ok, _} = Imports.sync_bookings(service, "ical", [entry("keep", 1, 10, 11)])

      bad = %{external_id: "bad", range: {at(1, 12), at(1, 11)}}

      assert {:error, {"bad", %Ecto.Changeset{}}} =
               Imports.sync_bookings(service, "ical", [entry("new", 2, 10, 11), bad])

      assert [%{external_id: "keep"}] = Imports.list_imported_bookings(service.uuid)
    end

    test "the (service, source, id) index refuses a duplicate row" do
      service = slot_service_fixture()
      {:ok, _} = Imports.sync_bookings(service, "ical", [entry("a", 1, 10, 11)])

      changeset =
        Booking.import_changeset(
          %Booking{},
          service.uuid,
          {at(2, 10), at(2, 11)},
          "ical",
          "a",
          %{}
        )

      assert {:error, cs} = PhoenixKit.RepoHelper.repo().insert(changeset)
      assert errors_on(cs)[:external_id]
    end
  end

  describe "sync_rules/4" do
    test "imported block-outs are replaced on re-sync, the admin's rules stay" do
      service = slot_service_fixture()
      own = business_hours_rule_fixture(service)
      d1 = Date.add(Date.utc_today(), 3)
      d2 = Date.add(Date.utc_today(), 4)

      assert {:ok, %{inserted: 2}} =
               Imports.sync_rules(service, "ical", [
                 %{external_id: "h1", date: d1, available: false},
                 %{external_id: "h2", date: d2, available: false}
               ])

      assert {:ok, %{deleted: 1, inserted: 0}} =
               Imports.sync_rules(service, "ical", [
                 %{external_id: "h1", date: d1, available: false}
               ])

      rules = Services.list_rules(service.uuid)
      assert Enum.any?(rules, &(&1.uuid == own.uuid and &1.source == "manual"))

      assert [%{external_id: "h1", source: "import"}] =
               Enum.filter(rules, &(&1.source == "import"))
    end
  end
end
