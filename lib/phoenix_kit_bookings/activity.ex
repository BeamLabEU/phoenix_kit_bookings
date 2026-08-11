defmodule PhoenixKitBookings.Activity do
  @moduledoc """
  Thin wrapper around `PhoenixKit.Activity.log/1` so callers don't need to
  duplicate the `Code.ensure_loaded?/1` guard and rescue clause everywhere.
  Safe to call from any LiveView — never crashes the caller.
  """

  require Logger

  @module "bookings"

  @doc "Logs a bookings activity entry via `PhoenixKit.Activity`. Swallows errors so it never crashes the caller."
  @spec log(String.t(), keyword()) ::
          :ok | :activity_unavailable | {:ok, struct()} | {:error, any()}
  def log(action, opts) when is_binary(action) and is_list(opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      entry = %{
        action: action,
        module: @module,
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        target_uuid: Keyword.get(opts, :target_uuid),
        metadata: Keyword.get(opts, :metadata, %{})
      }

      PhoenixKit.Activity.log(entry)
    else
      :activity_unavailable
    end
  rescue
    Postgrex.Error ->
      :ok

    DBConnection.OwnershipError ->
      :ok

    e ->
      Logger.warning("[Bookings] Activity logging error: #{Exception.message(e)}")
      {:error, e}
  catch
    :exit, _reason -> :ok
  end

  @doc "Extracts `user.uuid` from the LiveView socket assigns."
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end
end
