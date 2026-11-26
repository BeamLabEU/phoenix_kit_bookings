defmodule PhoenixKitBookings.ICalImport.HTTPFetcherTest do
  # Not async: the allowlist is application env.
  use ExUnit.Case, async: false

  alias PhoenixKitBookings.ICalImport.HTTPFetcher

  @feed "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"

  defmodule FeedPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/feed.ics"} = conn, _opts),
      do: conn |> put_resp_content_type("text/calendar") |> send_resp(200, feed())

    def call(%{request_path: "/to-localhost"} = conn, _opts) do
      conn
      |> put_resp_header("location", "http://localhost:#{conn.port}/feed.ics")
      |> send_resp(302, "")
    end

    # 200 only with the Basic credentials user / p@ss:word.
    def call(%{request_path: "/private"} = conn, _opts) do
      expected = "Basic " <> Base.encode64("user:p@ss:word")

      case get_req_header(conn, "authorization") do
        [^expected] -> send_resp(conn, 200, feed())
        _ -> send_resp(conn, 401, "")
      end
    end

    def call(%{request_path: "/to-localhost-private"} = conn, _opts) do
      conn
      |> put_resp_header("location", "http://localhost:#{conn.port}/private")
      |> send_resp(302, "")
    end

    def call(%{request_path: "/to-private"} = conn, _opts) do
      conn
      |> put_resp_header("location", "/private")
      |> send_resp(302, "")
    end

    def call(%{request_path: "/to-credentials"} = conn, _opts) do
      conn
      |> put_resp_header("location", "http://user:x@127.0.0.1:#{conn.port}/feed.ics")
      |> send_resp(302, "")
    end

    def call(%{request_path: "/to-self"} = conn, _opts) do
      conn
      |> put_resp_header("location", "/feed.ics")
      |> send_resp(302, "")
    end

    # 6 MB in chunks with no Content-Length: the cap must hold while streaming.
    def call(%{request_path: "/huge"} = conn, _opts) do
      conn = send_chunked(conn, 200)
      chunk = :binary.copy("X", 1024 * 1024)

      Enum.reduce_while(1..6, conn, fn _, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defp feed, do: "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"
  end

  setup do
    previous =
      for key <- [:ical_allowed_hosts, :ical_allowed_ports],
          do: {key, Application.fetch_env(:phoenix_kit_bookings, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:phoenix_kit_bookings, key, v)
          :error -> Application.delete_env(:phoenix_kit_bookings, key)
        end
      end
    end)

    :ok
  end

  defp start_server do
    pid =
      start_supervised!(
        {Bandit, plug: FeedPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:phoenix_kit_bookings, :ical_allowed_ports, [port])
    port
  end

  describe "without an allowlist" do
    test "refuses loopback, private, link-local and metadata hosts before connecting" do
      port = start_server()

      for url <- [
            "http://127.0.0.1:#{port}/feed.ics",
            "http://localhost:#{port}/feed.ics",
            "http://[::1]:#{port}/feed.ics",
            "http://10.0.0.1/feed.ics",
            "http://192.168.1.10/feed.ics",
            "http://172.16.5.5/feed.ics",
            "http://169.254.169.254/latest/meta-data/",
            "http://100.64.0.1/feed.ics",
            "http://0.0.0.0/feed.ics",
            "http://[fd00:ec2::254]/feed.ics",
            "http://[fe80::1]/feed.ics",
            "http://[::ffff:127.0.0.1]/feed.ics"
          ] do
        assert HTTPFetcher.fetch(url) == {:error, :blocked_host}, url
      end
    end

    test "refuses a port outside 80/443" do
      assert HTTPFetcher.fetch("http://example.com:5432/feed.ics") == {:error, :port_not_allowed}
    end
  end

  describe "with the host allowlisted" do
    test "fetches the feed" do
      port = start_server()
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1"])

      assert HTTPFetcher.fetch("http://127.0.0.1:#{port}/feed.ics") == {:ok, @feed}
    end

    test "follows a redirect to the same allowlisted host" do
      port = start_server()
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1"])

      assert HTTPFetcher.fetch("http://127.0.0.1:#{port}/to-self") == {:ok, @feed}
    end

    test "checks a redirect hop to a host that is not on the list" do
      port = start_server()
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1"])

      assert HTTPFetcher.fetch("http://127.0.0.1:#{port}/to-localhost") ==
               {:error, :blocked_host}
    end

    test "credentials in the URL go as Basic auth to its own origin only" do
      port = start_server()
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1", "localhost"])
      base = "http://user:p%40ss%3Aword@127.0.0.1:#{port}"

      assert HTTPFetcher.fetch(base <> "/private") == {:ok, @feed}
      # Same origin after a redirect: still sent.
      assert HTTPFetcher.fetch(base <> "/to-private") == {:ok, @feed}
      # Another host: not sent.
      assert HTTPFetcher.fetch(base <> "/to-localhost-private") == {:error, {:http_status, 401}}
      # Without them: refused by the server.
      assert HTTPFetcher.fetch("http://127.0.0.1:#{port}/private") ==
               {:error, {:http_status, 401}}
    end

    test "a redirect Location carrying credentials is refused" do
      port = start_server()
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1"])

      assert HTTPFetcher.fetch("http://127.0.0.1:#{port}/to-credentials") ==
               {:error, :invalid_url}
    end

    test "cuts a streamed body off at 5 MB" do
      port = start_server()
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1"])

      assert HTTPFetcher.fetch("http://127.0.0.1:#{port}/huge") == {:error, :too_large}
    end

    test "still refuses a port the config does not name" do
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["127.0.0.1"])
      assert HTTPFetcher.fetch("http://127.0.0.1:6379/") == {:error, :port_not_allowed}
    end
  end

  describe "redact/1 and unredact/2" do
    test "hide the password, and an unchanged redacted field keeps the stored one" do
      stored = "https://user:s3cret@cal.example.com/x.ics"
      shown = HTTPFetcher.redact(stored)

      assert shown == "https://user:*****@cal.example.com/x.ics"
      refute shown =~ "s3cret"

      assert HTTPFetcher.redact("https://cal.example.com/x.ics") ==
               "https://cal.example.com/x.ics"

      assert HTTPFetcher.redact(nil) == nil

      assert HTTPFetcher.unredact(shown, stored) == stored
      assert HTTPFetcher.unredact("https://other.example.com/y.ics", stored) =~ "other"
      assert HTTPFetcher.unredact(shown, nil) == shown
    end
  end

  describe "allowed_host?/1 and obviously_internal?/1" do
    test "match the allowlist case-insensitively, brackets and a trailing dot aside" do
      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["Calendar.LAN", "::1"])

      assert HTTPFetcher.allowed_host?("calendar.lan")
      assert HTTPFetcher.allowed_host?("calendar.lan.")
      assert HTTPFetcher.allowed_host?("[::1]")
      refute HTTPFetcher.allowed_host?("other.lan")
    end

    test "flag localhost and non-public IP literals unless allowlisted" do
      for url <- [
            "http://localhost/x.ics",
            "http://LOCALHOST./x.ics",
            "http://cal.localhost/x.ics",
            "http://127.0.0.1/x.ics",
            "http://10.1.2.3/x.ics",
            "http://169.254.169.254/",
            "webcal://[::1]/x.ics"
          ] do
        assert HTTPFetcher.obviously_internal?(url), url
      end

      for url <- ["https://calendar.google.com/x.ics", "http://8.8.8.8/x.ics", "not a url"] do
        refute HTTPFetcher.obviously_internal?(url), url
      end

      Application.put_env(:phoenix_kit_bookings, :ical_allowed_hosts, ["10.1.2.3"])
      refute HTTPFetcher.obviously_internal?("http://10.1.2.3/x.ics")
    end
  end
end
