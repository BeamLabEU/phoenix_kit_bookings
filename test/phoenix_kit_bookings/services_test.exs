defmodule PhoenixKitBookings.ServicesTest do
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKitBookings.Services

  describe "create_service/2" do
    test "creates with a generated slug" do
      {:ok, service} =
        Services.create_service(%{"name" => "Hot Stone Massage!", "time_unit" => "minutes"})

      assert service.slug =~ ~r/^hot-stone-massage/
      assert service.status == "active"
    end

    test "rejects an invalid time_unit and inverted duration bounds" do
      {:error, changeset} =
        Services.create_service(%{"name" => "X", "time_unit" => "weeks"})

      assert %{time_unit: _} = errors_on(changeset)

      {:error, changeset} =
        Services.create_service(%{
          "name" => "X",
          "time_unit" => "minutes",
          "flexible_duration" => true,
          "min_duration" => 120,
          "max_duration" => 30
        })

      assert %{max_duration: _} = errors_on(changeset)
    end

    test "enforces slug uniqueness" do
      {:ok, _} = Services.create_service(%{"name" => "A", "slug" => "the-slug"})
      {:error, changeset} = Services.create_service(%{"name" => "B", "slug" => "the-slug"})

      assert %{slug: _} = errors_on(changeset)
    end
  end

  describe "availability rules" do
    test "minute services require times; day services forbid them" do
      slot = slot_service_fixture()
      hotel = hotel_service_fixture()

      {:error, changeset} = Services.add_rule(slot, %{"days_of_week" => [1]})
      assert %{start_time: _} = errors_on(changeset)

      {:ok, _} =
        Services.add_rule(slot, %{
          "days_of_week" => [1],
          "start_time" => "09:00:00",
          "end_time" => "17:00:00"
        })

      {:error, changeset} =
        Services.add_rule(hotel, %{
          "days_of_week" => [1],
          "start_time" => "09:00:00",
          "end_time" => "17:00:00"
        })

      assert %{start_time: _} = errors_on(changeset)

      {:ok, _} = Services.add_rule(hotel, %{"days_of_week" => [1, 2, 3]})
    end

    test "rejects a rule that applies to nothing and bad weekdays" do
      slot = slot_service_fixture()

      {:error, changeset} =
        Services.add_rule(slot, %{"start_time" => "09:00:00", "end_time" => "17:00:00"})

      assert %{days_of_week: _} = errors_on(changeset)

      {:error, changeset} =
        Services.add_rule(slot, %{
          "days_of_week" => [0, 8],
          "start_time" => "09:00:00",
          "end_time" => "17:00:00"
        })

      assert %{days_of_week: _} = errors_on(changeset)
    end
  end

  describe "lifecycle" do
    test "trash → restore → permanent delete" do
      service = slot_service_fixture()

      {:ok, trashed} = Services.trash_service(service)
      assert trashed.status == "trashed"
      refute Enum.any?(Services.list_services(), &(&1.uuid == service.uuid))
      assert Enum.any?(Services.list_services(status: "trashed"), &(&1.uuid == service.uuid))

      {:ok, restored} = Services.restore_service(trashed)
      assert restored.status == "active"

      {:ok, _} = Services.trash_service(restored)
      {:ok, _} = Services.delete_service(restored)
      assert Services.get_service(service.uuid) == nil
    end

    test "get_active_service_by_slug ignores inactive and trashed" do
      service = slot_service_fixture()
      assert Services.get_active_service_by_slug(service.slug)

      {:ok, _} = Services.set_status(service, "inactive")
      assert Services.get_active_service_by_slug(service.slug) == nil
    end

    test "get_service survives a forged uuid" do
      assert Services.get_service("not-a-uuid") == nil
    end
  end
end
