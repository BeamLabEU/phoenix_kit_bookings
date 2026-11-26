defmodule PhoenixKitBookings.RegularSlots do
  @moduledoc """
  Regular slots: who usually has a weekly time (see
  `PhoenixKitBookings.Schemas.RegularSlot`).

  `conflicts/4` answers which active regular slots a new booking falls into
  whose holder is somebody else. `Bookings.create_booking/4` asks it inside
  the locked create and never refuses on it: the booking is created, flagged
  in `metadata["regular_slot_conflicts"]`, logged as
  `bookings.regular_slot_conflict`, and the owner is emailed
  (`Notifier.regular_slot_conflict/3`).
  """

  import Ecto.Query

  alias PhoenixKitBookings.{Activity, Engine, Services}
  alias PhoenixKitBookings.Schemas.{RegularSlot, Service}

  @doc "Slots of a service, by weekday then time."
  def list_slots(service_uuid) do
    from(r in RegularSlot,
      where: r.service_uuid == ^service_uuid,
      order_by: [asc: r.day_of_week, asc_nulls_first: r.start_time]
    )
    |> repo().all()
  end

  def get_slot(service_uuid, uuid) do
    repo().get_by(RegularSlot, uuid: uuid, service_uuid: service_uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Active regular slots of `service_uuid` that `range` touches and whose holder
  is not the booker (`user_uuid` / `email`).

  `range` is `{starts_at_utc, ends_at_utc}` (compared in the site frame
  `tz`) or `{:dates, starts_on, ends_on}`. A slot without times covers its
  whole weekday.
  """
  def conflicts(service_uuid, range, booker, tz \\ Engine.site_tz()) do
    case list_active(service_uuid) do
      [] ->
        []

      slots ->
        pieces = day_pieces(range, tz)

        Enum.filter(slots, fn slot ->
          not holder?(slot, booker) and Enum.any?(pieces, &touches?(slot, &1))
        end)
    end
  end

  defp list_active(service_uuid) do
    from(r in RegularSlot, where: r.service_uuid == ^service_uuid and r.active == true)
    |> repo().all()
  end

  # The booker holds the slot when the account or the address matches.
  defp holder?(%RegularSlot{} = slot, booker) do
    user_uuid = booker[:user_uuid]
    email = booker[:email]

    (not is_nil(slot.user_uuid) and slot.user_uuid == user_uuid) or
      (is_binary(slot.customer_email) and is_binary(email) and
         String.downcase(slot.customer_email) == String.downcase(String.trim(email)))
  end

  # A range as {date, from_time | nil, until_time | nil} pieces, one per frame
  # date it touches (nil = the whole day).
  defp day_pieces({%DateTime{} = starts_at, %DateTime{} = ends_at}, tz) do
    start_f = Engine.to_frame(starts_at, tz)
    end_f = Engine.to_frame(ends_at, tz)
    first = DateTime.to_date(start_f)
    last = end_f |> DateTime.add(-1, :second) |> DateTime.to_date()

    Enum.map(Date.range(first, last), fn date ->
      from_t = if date == first, do: DateTime.to_time(start_f), else: ~T[00:00:00]

      until_t =
        if date == DateTime.to_date(end_f), do: DateTime.to_time(end_f), else: ~T[23:59:59]

      {date, from_t, until_t}
    end)
  end

  defp day_pieces({:dates, %Date{} = starts_on, %Date{} = ends_on}, _tz) do
    starts_on
    |> Date.range(Date.add(ends_on, -1))
    |> Enum.map(&{&1, nil, nil})
  end

  defp day_pieces(_range, _tz), do: []

  defp touches?(%RegularSlot{day_of_week: dow} = slot, {date, from_t, until_t}) do
    Date.day_of_week(date) == dow and times_overlap?(slot, from_t, until_t)
  end

  defp times_overlap?(%RegularSlot{start_time: nil}, _from, _until), do: true
  defp times_overlap?(_slot, nil, _until), do: true

  defp times_overlap?(%RegularSlot{start_time: s, end_time: e}, from_t, until_t) do
    Time.compare(from_t, e) == :lt and Time.compare(s, until_t) == :lt
  end

  @doc "The metadata a flagged booking carries: one entry per slot."
  def conflict_metadata(slots) do
    Enum.map(slots, fn slot ->
      %{
        "slot_uuid" => slot.uuid,
        "holder_name" => slot.customer_name,
        "holder_email" => slot.customer_email,
        "holder_user_uuid" => slot.user_uuid
      }
    end)
  end

  # ── Mutations ────────────────────────────────────────────────────────

  def create_slot(%Service{} = service, attrs, opts \\ []) do
    %RegularSlot{}
    |> RegularSlot.changeset(attrs)
    |> Ecto.Changeset.put_change(:service_uuid, service.uuid)
    |> repo().insert()
    |> tap_log("bookings.regular_slot_added", service.uuid, opts)
  end

  def update_slot(%RegularSlot{} = slot, attrs, opts \\ []) do
    slot
    |> RegularSlot.changeset(attrs)
    |> repo().update()
    |> tap_log("bookings.regular_slot_updated", slot.service_uuid, opts)
  end

  def delete_slot(%RegularSlot{} = slot, opts \\ []) do
    slot
    |> repo().delete()
    |> tap_log("bookings.regular_slot_removed", slot.service_uuid, opts)
  end

  defp tap_log({:ok, slot} = result, action, service_uuid, opts) do
    Activity.log(action,
      actor_uuid: opts[:actor_uuid],
      resource_type: "bookings_service",
      resource_uuid: service_uuid,
      metadata: %{"day_of_week" => slot.day_of_week}
    )

    Services.broadcast_changed(service_uuid)
    result
  end

  defp tap_log(result, _action, _service_uuid, _opts), do: result

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
