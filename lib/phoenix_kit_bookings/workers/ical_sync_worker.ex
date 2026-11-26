defmodule PhoenixKitBookings.Workers.ICalSyncWorker do
  @moduledoc """
  Syncs iCal feeds (`PhoenixKitBookings.ICalImport`) on the module's own
  `bookings_sync` queue (declared by `PhoenixKitBookings.oban_queues/0`).

  - `%{"service_uuid" => uuid}` — sync that service.
  - no args — the hourly cron (`PhoenixKitBookings.oban_crons/0`): enqueue
    one job per service with a feed. Does nothing while the module is
    disabled.

  Jobs for one service are unique for a minute, so a double "Sync now" and
  the cron do not race each other into the same feed.
  """

  use Oban.Worker,
    queue: :bookings_sync,
    max_attempts: 3,
    unique: [period: 60, keys: [:service_uuid]]

  alias PhoenixKitBookings.{ICalImport, Services}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"service_uuid" => uuid}}) do
    case Services.get_service(uuid) do
      %{status: status} = service when status != "trashed" ->
        case ICalImport.sync_service(service) do
          {:ok, _stats} -> :ok
          {:error, :no_url} -> :ok
          # A feed that answers with an error is recorded on the service; a
          # retry within the hour rarely helps, the next cron run will.
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{}) do
    if PhoenixKitBookings.enabled?() do
      Enum.each(ICalImport.list_feed_services(), &enqueue(&1.uuid))
    end

    :ok
  end

  @doc "Enqueues a sync of one service. `{:ok, job}` or `{:error, reason}`."
  def enqueue(service_uuid) do
    %{"service_uuid" => service_uuid}
    |> new()
    |> Oban.insert()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end
end
