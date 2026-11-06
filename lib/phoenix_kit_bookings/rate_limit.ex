defmodule PhoenixKitBookings.RateLimit do
  @moduledoc """
  A ceiling on what a public visitor can make this module send.

  A guest booking or a waitlist entry mails the address it was given, with a name
  the visitor typed in the body, so an open form is a way to mail a stranger.
  `check/2` counts one attempt against the address and against the peer, per hour,
  on core's limiter.

  The address bucket is the one that protects a person, and it works whatever the
  host's endpoint exposes. The peer comes from LiveView's `:peer_data`, so it
  needs `connect_info: [:peer_data, session: ...]` on the host's socket; without
  it the bucket is skipped. Behind a proxy the host resolves the real address
  before Phoenix (`RemoteIp`): forwarded headers are never read here.

  A limiter that is not running allows the attempt. Capacity is decided by the
  locked create either way, and taking bookings is what this module is for.

  Limits: `config :phoenix_kit_bookings, :public_rate_limit, per_address: 10,
  per_peer: 30`.
  """

  require Logger

  alias PhoenixKit.Users.RateLimiter

  @hour_ms 60 * 60 * 1000
  @defaults [per_address: 10, per_peer: 30]

  @doc "Counts one attempt. `:ok`, or `{:error, :rate_limited}` past a limit."
  @spec check(term(), :inet.ip_address() | nil) :: :ok | {:error, :rate_limited}
  def check(email, peer_ip) do
    limits = Keyword.merge(@defaults, configured_limits())

    [address_bucket(email, limits), peer_bucket(peer_ip, limits)]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn {key, limit}, :ok ->
      case RateLimiter.Backend.hit(key, @hour_ms, limit) do
        {:allow, _count} -> {:cont, :ok}
        _denied -> {:halt, {:error, :rate_limited}}
      end
    end)
  rescue
    e ->
      Logger.warning("[Bookings] rate limiter unavailable: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[Bookings] rate limiter unavailable: #{inspect(reason)}")
      :ok
  end

  defp configured_limits, do: Application.get_env(:phoenix_kit_bookings, :public_rate_limit, [])

  defp address_bucket(email, limits) when is_binary(email) and email != "" do
    {"bookings:address:#{email |> String.trim() |> String.downcase()}", limits[:per_address]}
  end

  defp address_bucket(_email, _limits), do: nil

  defp peer_bucket(nil, _limits), do: nil
  defp peer_bucket(ip, limits), do: {"bookings:peer:#{ip_bucket(ip)}", limits[:per_peer]}

  # IPv6 by its /64: one subscriber holds a whole prefix, so a single address
  # would be free to rotate.
  defp ip_bucket({a, b, c, d, _, _, _, _}), do: Enum.join([a, b, c, d], ":") <> "::/64"
  defp ip_bucket(ip), do: ip |> :inet.ntoa() |> to_string()
end
