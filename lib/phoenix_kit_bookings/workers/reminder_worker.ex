defmodule PhoenixKitBookings.Workers.ReminderWorker do
  @moduledoc """
  Sends the reminder email at `starts_at - reminder_minutes` (scheduled at
  booking creation via `scheduled_at:` — the `:default` queue, which every
  Oban install runs). The job re-checks state at fire time: a cancelled
  booking or a service whose reminder was turned off sends nothing, so
  stale jobs are harmless and no cancellation bookkeeping is needed.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias PhoenixKitBookings.{Bookings, Notifier, Services}
  alias PhoenixKitBookings.Schemas.Booking

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_uuid" => booking_uuid}}) do
    with %Booking{status: status} = booking when status in ["pending", "confirmed"] <-
           Bookings.get_booking(booking_uuid),
         %{reminder_minutes: minutes} = service when is_integer(minutes) <-
           Services.get_service(booking.service_uuid) do
      Notifier.reminder(booking, service)
      :ok
    else
      # Booking gone/cancelled or reminders disabled — nothing to send.
      _ -> :ok
    end
  end

  @doc """
  Schedules the reminder for a fresh booking. Best-effort: no reminder
  configured, a day-mode booking (no clock time to anchor), a reminder
  moment already in the past, or Oban not running (module test suite) all
  no-op.
  """
  def schedule(%Booking{starts_at: %DateTime{} = starts_at} = booking, %{
        reminder_minutes: minutes
      })
      when is_integer(minutes) do
    at = DateTime.add(starts_at, -minutes * 60, :second)

    if DateTime.compare(at, DateTime.utc_now()) == :gt do
      %{"booking_uuid" => booking.uuid}
      |> new(scheduled_at: at)
      |> Oban.insert()

      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def schedule(_booking, _service), do: :ok
end
