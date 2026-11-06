defmodule PhoenixKitBookings.RateLimitTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBookings.RateLimit

  defp address, do: "person-#{System.unique_integer([:positive])}@example.com"
  defp peer, do: {10, 0, rem(System.unique_integer([:positive]), 250), 1}

  test "an address has a ceiling, whichever way it is typed" do
    email = address()

    for _ <- 1..10, do: assert(:ok = RateLimit.check(email, nil))

    assert {:error, :rate_limited} = RateLimit.check(String.upcase(email), nil)
  end

  test "a peer has its own ceiling, across addresses" do
    ip = peer()

    for _ <- 1..30, do: assert(:ok = RateLimit.check(address(), ip))

    assert {:error, :rate_limited} = RateLimit.check(address(), ip)
  end

  test "an IPv6 subscriber is one peer, however it rotates its address" do
    prefix = rem(System.unique_integer([:positive]), 60_000)

    for host <- 1..30 do
      assert :ok = RateLimit.check(address(), {0x2001, 0xDB8, prefix, 1, 0, 0, 0, host})
    end

    assert {:error, :rate_limited} =
             RateLimit.check(address(), {0x2001, 0xDB8, prefix, 1, 9, 9, 9, 9})
  end

  test "with no address and no peer there is nothing to count" do
    assert :ok = RateLimit.check(nil, nil)
  end
end
