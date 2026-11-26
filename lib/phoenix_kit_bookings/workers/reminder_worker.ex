defmodule PhoenixKitBookings.Workers.ReminderWorker do
  @moduledoc """
  Sends the reminder email at `starts_at - reminder_minutes` (scheduled at
  booking creation via `scheduled_at:` — the `:default` queue, which every
  Oban install runs). The job re-checks state at fire time: a cancelled
  booking or a service whose reminder was turned off sends nothing, so
  stale jobs are harmless and no cancellation bookkeeping is needed. A job
  carries the start it was scheduled for (`"starts_at"`); a booking moved
  since then (an event rescheduled) has a new job, and the old one sends
  nothing.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias PhoenixKitBookings.{Bookings, Notifier, Services}
  alias PhoenixKitBookings.Schemas.Booking

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_uuid" => booking_uuid} = args}) do
    with %Booking{status: status} = booking when status in ["pending", "confirmed"] <-
           Bookings.get_booking(booking_uuid),
         true <- same_start?(args["starts_at"], booking.starts_at),
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
      # One pending job per booking and start: an event moved away and back
      # again must not leave two reminders for the same time.
      %{"booking_uuid" => booking.uuid, "starts_at" => DateTime.to_iso8601(starts_at)}
      |> new(
        scheduled_at: at,
        unique: [
          period: :infinity,
          keys: [:booking_uuid, :starts_at],
          states: [:available, :scheduled, :retryable]
        ]
      )
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

  # Jobs from before the start was recorded carry none and still fire.
  defp same_start?(nil, _starts_at), do: true

  defp same_start?(iso, %DateTime{} = starts_at) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.compare(at, starts_at) == :eq
      _ -> true
    end
  end

  defp same_start?(_iso, _starts_at), do: true
end
