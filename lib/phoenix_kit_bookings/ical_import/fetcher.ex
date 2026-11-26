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
  that resolves to an internal address). On Mint, the same way core's
  `Storage.RemoteFetch` works:

    * `http` and `https`, ports 80 and 443;
    * the host is resolved once and EVERY address it resolves to must be
      public (`PhoenixKit.Utils.PublicAddress`: loopback, private, link-local,
      CGNAT, multicast, reserved and the IPv6 forms that carry an IPv4
      address are refused); the connection goes to the address that was
      checked, with the name for `Host`, SNI and certificate verification, so
      DNS cannot answer differently a moment later;
    * redirects (at most 5) are followed by hand and every hop is checked
      again; an https feed never redirects to http;
    * the body is cut off at 5 MB while it streams, whatever
      `Content-Length` says, within 20 seconds overall.

  ## Credentials

  A private feed URL may carry them (`https://user:secret@cal.example.com/x.ics`).
  They are taken out of the URL and sent as HTTP Basic `Authorization`, only
  to the URL's own origin (scheme, host and port): a redirect elsewhere goes
  without them, and a redirect `Location` that itself carries credentials is
  refused (`:invalid_url`). They never appear in a returned reason; the
  admin form shows the URL through `redact/1`.

  ## The local network

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

  alias PhoenixKit.Utils.PublicAddress

  @max_bytes 5 * 1024 * 1024
  @timeout 20_000
  @max_redirects 5
  @default_ports [80, 443]
  @redirects [301, 302, 303, 307, 308]

  @impl true
  def fetch(url) when is_binary(url) do
    deadline = System.monotonic_time(:millisecond) + @timeout
    %URI{userinfo: userinfo} = uri = URI.parse(url)
    get(%{uri | userinfo: nil}, auth_for(uri, userinfo), @max_redirects, deadline, nil)
  rescue
    _ -> {:error, :invalid_url}
  end

  # The credentials and the origin they may go to.
  defp auth_for(_uri, nil), do: nil

  defp auth_for(uri, userinfo) do
    {user, password} =
      case String.split(userinfo, ":", parts: 2) do
        [user, password] -> {URI.decode(user), URI.decode(password)}
        [user] -> {URI.decode(user), ""}
      end

    %{origin: origin(uri), header: "Basic " <> Base.encode64(user <> ":" <> password)}
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}),
    do: {scheme, host && String.downcase(host), port}

  defp get(uri, auth, redirects_left, deadline, previous_scheme) do
    with :ok <- validate(uri, previous_scheme),
         {:ok, ip} <- resolve(uri.host),
         {:ok, conn} <- connect(uri, ip, deadline) do
      case request(conn, uri, auth, deadline) do
        {:redirect, location} when redirects_left > 0 ->
          follow(uri, location, auth, redirects_left, deadline)

        {:redirect, _location} ->
          {:error, :too_many_redirects}

        other ->
          other
      end
    end
  end

  defp follow(uri, location, auth, redirects_left, deadline) do
    case URI.parse(location) do
      %URI{userinfo: nil} ->
        next = URI.merge(uri, location)
        get(next, auth, redirects_left - 1, deadline, uri.scheme)

      _with_credentials ->
        {:error, :invalid_url}
    end
  end

  defp validate(%URI{scheme: scheme, host: host, port: port}, previous_scheme) do
    cond do
      host in [nil, ""] or scheme in [nil, ""] -> {:error, :invalid_url}
      scheme not in ["http", "https"] -> {:error, :scheme_not_allowed}
      previous_scheme == "https" and scheme != "https" -> {:error, :scheme_not_allowed}
      port not in allowed_ports() -> {:error, :port_not_allowed}
      true -> :ok
    end
  end

  defp connect(uri, ip, deadline) do
    scheme = if uri.scheme == "https", do: :https, else: :http

    case Mint.HTTP.connect(scheme, ip, uri.port,
           hostname: uri.host,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: max(remaining(deadline), 1)]
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, error} -> {:error, {:connect_failed, error}}
    end
  end

  defp request(conn, uri, auth, deadline) do
    path =
      case {uri.path, uri.query} do
        {p, nil} -> if(p in [nil, ""], do: "/", else: p)
        {p, q} -> if(p in [nil, ""], do: "/", else: p) <> "?" <> q
      end

    headers =
      [
        {"user-agent", "PhoenixKitBookings iCal import"},
        {"accept", "text/calendar, */*"}
      ] ++ auth_header(auth, uri)

    case Mint.HTTP.request(conn, "GET", path, headers, nil) do
      {:ok, conn, ref} ->
        receive_loop(conn, ref, %{status: nil, body: [], bytes: 0}, deadline)

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:error, {:connect_failed, error}}
    end
  end

  defp auth_header(nil, _uri), do: []

  defp auth_header(%{origin: origin, header: header}, uri) do
    if origin(uri) == origin, do: [{"authorization", header}], else: []
  end

  defp receive_loop(conn, ref, state, deadline) do
    case remaining(deadline) do
      0 ->
        finish(conn, {:error, :timeout})

      timeout ->
        conn |> Mint.HTTP.recv(0, timeout) |> received(ref, state, deadline)
    end
  end

  defp received({:ok, conn, responses}, ref, state, deadline) do
    case handle(responses, ref, state) do
      {:cont, state} -> receive_loop(conn, ref, state, deadline)
      {:done, result} -> finish(conn, result)
    end
  end

  defp received({:error, conn, %Mint.TransportError{reason: :timeout}, _}, _ref, _state, _dl),
    do: finish(conn, {:error, :timeout})

  defp received({:error, conn, error, _}, _ref, _state, _deadline),
    do: finish(conn, {:error, {:connect_failed, error}})

  @doc false
  # One batch of Mint responses folded into the download state.
  def handle([], _ref, state), do: {:cont, state}

  def handle([{:status, ref, status} | rest], ref, state),
    do: handle(rest, ref, %{state | status: status})

  # An interim response (100 Continue, 103 Early Hints): its headers carry
  # nothing wanted, and the final status follows on the same request.
  def handle([{:headers, ref, _headers} | rest], ref, %{status: status} = state)
      when status in 100..199,
      do: handle(rest, ref, %{state | status: nil})

  def handle([{:headers, ref, headers} | _rest], ref, %{status: status})
      when status in @redirects do
    case header(headers, "location") do
      nil -> {:done, {:error, {:http_status, status}}}
      location -> {:done, {:redirect, location}}
    end
  end

  def handle([{:headers, ref, _headers} | _rest], ref, %{status: status})
      when status != 200,
      do: {:done, {:error, {:http_status, status}}}

  def handle([{:headers, ref, headers} | rest], ref, state) do
    if too_long?(headers, state),
      do: {:done, {:error, :too_large}},
      else: handle(rest, ref, state)
  end

  def handle([{:data, ref, data} | rest], ref, state) do
    bytes = state.bytes + byte_size(data)

    if bytes > @max_bytes,
      do: {:done, {:error, :too_large}},
      else: handle(rest, ref, %{state | body: [state.body, data], bytes: bytes})
  end

  def handle([{:done, ref} | _rest], ref, %{status: 200} = state),
    do: {:done, {:ok, IO.iodata_to_binary(state.body)}}

  def handle([_other | rest], ref, state), do: handle(rest, ref, state)

  defp too_long?(headers, %{bytes: 0}) do
    case header(headers, "content-length") do
      nil ->
        false

      value ->
        case Integer.parse(value) do
          {n, _} -> n > @max_bytes
          :error -> false
        end
    end
  end

  # Trailers after the body began carry nothing wanted.
  defp too_long?(_headers, _state), do: false

  defp header(headers, name),
    do:
      Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)

  defp finish(conn, result) do
    Mint.HTTP.close(conn)
    result
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  The URL with any password replaced by `*****` — what the admin form shows
  and what may appear in a log. `nil` stays `nil`.
  """
  def redact(nil), do: nil

  def redact(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} = uri when is_binary(userinfo) ->
        user = userinfo |> String.split(":", parts: 2) |> hd()
        URI.to_string(%{uri | userinfo: user <> ":*****"})

      _ ->
        url
    end
  end

  @doc """
  What the admin form submitted, with a redacted URL put back to the stored
  one: an unchanged field must not overwrite the password with `*****`.
  """
  def unredact(submitted, stored) do
    if is_binary(stored) and submitted == redact(stored), do: stored, else: submitted
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
