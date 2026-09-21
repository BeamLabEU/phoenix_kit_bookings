defmodule PhoenixKitBookings.NotifyTest do
  @moduledoc """
  `notify: false` — creating, approving and cancelling a booking without
  contacting its customer.

  Not async: a real Oban instance (manual testing mode) is started under the
  default `Oban` name, because `ReminderWorker.schedule/2` inserts through
  it. Without one the insert fails, is rescued, and "no reminder was
  scheduled" would pass whether or not the option worked — so the first
  test is a control proving a reminder IS visible here when it should be.
  """
  use PhoenixKitBookings.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitBookings.Test.Repo

  import Swoosh.TestAssertions

  alias PhoenixKitBookings.Bookings
  alias PhoenixKitBookings.Workers.ReminderWorker

  setup do
    start_supervised!({Oban, repo: PhoenixKitBookings.Test.Repo, testing: :manual})
    :ok
  end

  defp tomorrow_at(hour) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  # A reminder an hour before a booking tomorrow is always in the future,
  # so the worker has no reason of its own to skip scheduling it.
  defp reminding_service(attrs \\ %{}) do
    slot_service_fixture(Map.merge(%{"reminder_minutes" => 60}, attrs))
  end

  defp range, do: {tomorrow_at(10), tomorrow_at(11)}

  describe "create_booking/4" do
    test "control: by default the customer is emailed and a reminder is scheduled" do
      {:ok, booking} = Bookings.create_booking(reminding_service(), range(), customer_attrs())

      assert_email_sent(fn email -> assert email.subject =~ "Booking confirmed" end)
      assert_enqueued(worker: ReminderWorker, args: %{"booking_uuid" => booking.uuid})
    end

    test "notify: false creates the booking and contacts nobody" do
      service = reminding_service(%{"price" => "20", "price_per" => "hour"})

      {:ok, booking} =
        Bookings.create_booking(service, range(), customer_attrs(), notify: false)

      # The booking itself is exactly what it would have been.
      assert booking.status == "confirmed"
      assert Decimal.equal?(booking.total_price, Decimal.new("20"))

      assert_no_email_sent()
      refute_enqueued(worker: ReminderWorker)
    end

    test "only an explicit false silences it" do
      for value <- [nil, true, "false", :no] do
        {:ok, booking} =
          Bookings.create_booking(reminding_service(), range(), customer_attrs(), notify: value)

        assert_email_sent(fn email -> assert email.subject =~ "Booking confirmed" end)
        assert_enqueued(worker: ReminderWorker, args: %{"booking_uuid" => booking.uuid})
      end
    end
  end

  describe "confirm_booking/2" do
    test "notify: false approves without the approval email" do
      service = reminding_service(%{"require_approval" => true})

      {:ok, pending} =
        Bookings.create_booking(service, range(), customer_attrs(), notify: false)

      assert pending.status == "pending"
      assert_no_email_sent()

      {:ok, confirmed} = Bookings.confirm_booking(pending, notify: false)
      assert confirmed.status == "confirmed"
      assert_no_email_sent()
    end
  end

  describe "cancel_booking/2" do
    test "notify: false spares this customer but still tells the waitlist" do
      service = reminding_service()

      {:ok, booking} =
        Bookings.create_booking(service, range(), customer_attrs(), notify: false)

      {:ok, _} =
        Bookings.join_waitlist(service, %{
          "date" => Date.to_iso8601(Date.add(Date.utc_today(), 1)),
          "customer_name" => "Waiting Guest",
          "customer_email" => "waiting@example.com"
        })

      {:ok, cancelled} = Bookings.cancel_booking(booking, notify: false)
      assert cancelled.status == "cancelled"

      # The only mail is to the person on the waitlist — never "cancelled".
      assert_email_sent(fn email ->
        assert email.subject =~ "A spot opened up"
        assert Enum.any?(email.to, fn {_name, addr} -> addr == "waiting@example.com" end)
      end)

      assert_no_email_sent()
    end
  end
end
