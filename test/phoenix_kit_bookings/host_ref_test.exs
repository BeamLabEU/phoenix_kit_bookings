defmodule PhoenixKitBookings.HostRefTest do
  use PhoenixKitBookings.DataCase, async: true

  alias PhoenixKitBookings.Services

  test "a service is found by its host ref; trashed ones are not" do
    service = slot_service_fixture(%{"host_ref" => "machine:42"})
    _other = slot_service_fixture(%{"host_ref" => "machine:43"})

    assert Services.get_service_by_host_ref("machine:42").uuid == service.uuid
    assert [%{uuid: uuid}] = Services.list_services(host_ref: "machine:42")
    assert uuid == service.uuid

    {:ok, _} = Services.trash_service(service)
    assert Services.get_service_by_host_ref("machine:42") == nil
    assert Services.get_service_by_host_ref("nothing") == nil
  end

  test "blank is nil, and the ref is optional" do
    service = slot_service_fixture(%{"host_ref" => "  "})
    assert service.host_ref == nil
    assert slot_service_fixture().host_ref == nil
  end

  test "the ref is indexed" do
    %{rows: [[found]]} =
      PhoenixKitBookings.Test.Repo.query!(
        "SELECT to_regclass('public.phoenix_kit_bookings_services_host_ref_index') IS NOT NULL"
      )

    assert found
  end
end
