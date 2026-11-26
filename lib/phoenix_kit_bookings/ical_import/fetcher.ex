defmodule PhoenixKitBookings.ICalImport.Fetcher do
  @moduledoc """
  How a feed is fetched. The default is `ReqFetcher`; tests and hosts with
  their own HTTP stack swap it:

      config :phoenix_kit_bookings, :ical_fetcher, MyApp.ICalFetcher

  `fetch/1` gets an `https://` / `http://` URL (a `webcal://` link is turned
  into `https://` first) and returns `{:ok, body}` or `{:error, reason}`.
  """

  @callback fetch(url :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "The configured fetcher module."
  def impl do
    Application.get_env(
      :phoenix_kit_bookings,
      :ical_fetcher,
      PhoenixKitBookings.ICalImport.ReqFetcher
    )
  end
end

defmodule PhoenixKitBookings.ICalImport.ReqFetcher do
  @moduledoc """
  The default feed fetcher, on `Req` (core's HTTP client): a GET with a
  15-second timeout, redirects followed (at most 5), no retries, a body
  capped at 5 MB, and a plain User-Agent.
  """

  @behaviour PhoenixKitBookings.ICalImport.Fetcher

  @max_bytes 5 * 1024 * 1024

  @impl true
  def fetch(url) do
    case Req.get(url,
           receive_timeout: 15_000,
           connect_options: [timeout: 10_000],
           max_redirects: 5,
           retry: false,
           decode_body: false,
           headers: [
             {"user-agent", "PhoenixKitBookings iCal import"},
             {"accept", "text/calendar, */*"}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if byte_size(body) > @max_bytes, do: {:error, :too_large}, else: {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  rescue
    e -> {:error, e}
  end
end
