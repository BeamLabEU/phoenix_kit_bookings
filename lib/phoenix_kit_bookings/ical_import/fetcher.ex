defmodule PhoenixKitBookings.ICalImport.Fetcher do
  @moduledoc """
  How a feed is fetched. The default is `HTTPFetcher`; tests and hosts with
  their own HTTP stack swap it:

      config :phoenix_kit_bookings, :ical_fetcher, MyApp.ICalFetcher

  `fetch/1` gets an `https://` / `http://` URL (a `webcal://` link is turned
  into `https://` first) and returns `{:ok, body}` or `{:error, reason}`.
  A replacement fetcher takes over the network guard too: the URL is admin
  input, so it must not let the server reach its own network.
  """

  @callback fetch(url :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "The configured fetcher module."
  def impl do
    Application.get_env(
      :phoenix_kit_bookings,
      :ical_fetcher,
      PhoenixKitBookings.ICalImport.HTTPFetcher
    )
  end
end

defmodule PhoenixKitBookings.ICalImport.HTTPFetcher do
  @moduledoc """
  The default feed fetcher. A feed URL is a request for the server to
  connect somewhere an admin chose, so the fetch must not reach the server's
  own network (`http://169.254.169.254/`, `http://localhost:5432/`, a name
  that resolves to an internal address). It runs on core's
  `PhoenixKit.Modules.Storage.RemoteFetch`:

    * `http` and `https`, no credentials in the URL, ports 80 and 443;
    * the host is resolved once and EVERY address it resolves to must be
      public (`PhoenixKit.Utils.PublicAddress`: loopback, private, link-local,
      CGNAT, multicast, reserved and the IPv6 forms that carry an IPv4
      address are refused); the connection goes to the address that was
      checked, so DNS cannot answer differently a moment later;
    * redirects (at most 5) are followed by hand and every hop is checked
      again; an https feed never redirects to http;
    * the body is cut off at 5 MB while it streams, whatever
      `Content-Length` says, within 20 seconds overall.

  A feed that really lives on the local network (a calendar server on the
  LAN) is let through by naming its host as it appears in the URL (case and
  a trailing dot aside), and any extra port it needs:

      config :phoenix_kit_bookings,
        ical_allowed_hosts: ["calendar.lan", "10.0.0.12"],
        ical_allowed_ports: [80, 443, 8443]

  A named host may resolve to any address; a redirect from it to a host not
  on the list is checked like any other.
  """

  @behaviour PhoenixKitBookings.ICalImport.Fetcher

  alias PhoenixKit.Modules.Storage.RemoteFetch
  alias PhoenixKit.Utils.PublicAddress

  @max_bytes 5 * 1024 * 1024
  @timeout 20_000
  @max_redirects 5
  @default_ports [80, 443]

  @impl true
  def fetch(url) when is_binary(url) do
    case RemoteFetch.download(url,
           allow_http: true,
           allowed_ports: allowed_ports(),
           max_bytes: @max_bytes,
           max_redirects: @max_redirects,
           timeout: @timeout,
           accept: "text/calendar, */*",
           protocols: [:http1],
           # Every hop's host goes through `resolve/1`: the public-address
           # check, unless the host is on the configured allowlist.
           unsafe_resolver: &resolve/1
         ) do
      {:ok, %{path: path}} -> read_and_remove(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_and_remove(path) do
    File.read(path)
  after
    File.rm(path)
  end

  @doc """
  The address to connect to for `host`: any address of an allowlisted host,
  otherwise only a host whose every address is public. `{:ok, ip}` or
  `{:error, :blocked_host | :nxdomain}`.
  """
  def resolve(host) when is_binary(host) do
    if allowed_host?(host), do: resolve_any(host), else: PublicAddress.resolve_public(host)
  end

  @doc "Whether `host` is on the `:ical_allowed_hosts` list (case-insensitive)."
  def allowed_host?(host) when is_binary(host) do
    host = normalize_host(host)
    Enum.any?(allowed_hosts(), &(&1 == host))
  end

  def allowed_host?(_host), do: false

  @doc """
  Whether the URL's host is plainly internal on its face — `localhost`, or a
  literal IP that is not public — and not allowlisted. A form can say so at
  once; the fetch checks again after resolving, which is what catches a name
  pointing inside.
  """
  def obviously_internal?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        bare = normalize_host(host)

        not allowed_host?(bare) and
          (bare == "localhost" or String.ends_with?(bare, ".localhost") or
             (ip_literal?(bare) and not PublicAddress.public?(bare)))

      _ ->
        false
    end
  end

  def obviously_internal?(_url), do: false

  defp ip_literal?(host),
    do: match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))

  defp resolve_any(host) do
    bare = host |> String.trim_leading("[") |> String.trim_trailing("]")
    charlist = String.to_charlist(bare)

    case :inet.parse_strict_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        Enum.find_value([:inet, :inet6], {:error, :nxdomain}, &getaddr(charlist, &1))
    end
  end

  defp getaddr(charlist, family) do
    case :inet.getaddr(charlist, family) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> nil
    end
  end

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp allowed_hosts do
    :phoenix_kit_bookings
    |> Application.get_env(:ical_allowed_hosts, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_host/1)
  end

  defp allowed_ports do
    case Application.get_env(:phoenix_kit_bookings, :ical_allowed_ports) do
      ports when is_list(ports) and ports != [] ->
        Enum.uniq(@default_ports ++ Enum.filter(ports, &is_integer/1))

      _ ->
        @default_ports
    end
  end
end
