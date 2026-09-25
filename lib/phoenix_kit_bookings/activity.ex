defmodule PhoenixKitBookings.Activity do
  @moduledoc """
  The bookings module's activity log: `PhoenixKit.Activity.log/3` under the
  `"bookings"` module key. Never crashes the caller — core logs a failure
  and returns it as `{:error, _}`.
  """

  @module "bookings"

  @doc "Logs a bookings activity entry. Options as `PhoenixKit.Activity.log/3`."
  @spec log(String.t(), keyword()) :: {:ok, struct()} | {:error, any()}
  def log(action, opts) when is_binary(action) and is_list(opts),
    do: PhoenixKit.Activity.log(@module, action, opts)
end
