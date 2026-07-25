defmodule PhoenixKitBookings.Notifier do
  @moduledoc """
  Transactional email for the booking lifecycle, via core's
  `PhoenixKit.Mailer` (routes through Integrations → parent mailer →
  built-in, honors the blocklist). Every send is best-effort — a mail
  failure must never fail the booking operation (the newsletters worker
  convention). Confirmation emails attach an `.ics` calendar file.
  """

  require Logger

  alias PhoenixKitBookings.{Bookings, ICS, Paths}
  alias PhoenixKitBookings.Schemas.{Booking, Service, WaitlistEntry}
  alias PhoenixKitBookings.Web.Format

  @doc "Right email for a fresh booking (confirmed vs pending-approval)."
  def booking_created(%Booking{status: "pending"} = booking, %Service{} = service) do
    deliver(
      booking.customer_email,
      "Booking request received — #{service.name}",
      """
      Hi #{booking.customer_name},

      Your request for #{service.name} (#{Format.format_range(booking)}) has been
      received and is waiting for approval. You'll get another email once it's
      decided.

      Manage or cancel: #{manage_url(booking)}
      """,
      []
    )
  end

  def booking_created(%Booking{} = booking, %Service{} = service) do
    confirmation(booking, service, "Booking confirmed — #{service.name}")
  end

  @doc "Pending → confirmed (approval granted)."
  def booking_confirmed(%Booking{} = booking, %Service{} = service) do
    confirmation(booking, service, "Booking approved — #{service.name}")
  end

  def booking_cancelled(%Booking{} = booking, %Service{} = service) do
    deliver(
      booking.customer_email,
      "Booking cancelled — #{service.name}",
      """
      Hi #{booking.customer_name},

      Your booking for #{service.name} (#{Format.format_range(booking)}) has been
      cancelled.

      Book again: #{Paths.public_book_url(service.slug)}
      """,
      []
    )
  end

  def reminder(%Booking{} = booking, %Service{} = service) do
    deliver(
      booking.customer_email,
      "Reminder — #{service.name} #{Format.format_range(booking)}",
      """
      Hi #{booking.customer_name},

      A reminder about your upcoming booking: #{service.name},
      #{Format.format_range(booking)}.

      Manage or cancel: #{manage_url(booking)}
      """,
      []
    )
  end

  @doc "A cancellation freed capacity on a date this entry waits for."
  def waitlist_opening(%WaitlistEntry{} = entry, %Service{} = service, %Date{} = date) do
    deliver(
      entry.customer_email,
      "A spot opened up — #{service.name}",
      """
      Hi #{entry.customer_name},

      Availability just opened up for #{service.name} on
      #{Calendar.strftime(date, "%d %b %Y")}. First come, first served:

      #{Paths.public_book_url(service.slug)}
      """,
      []
    )
  end

  defp confirmation(booking, service, subject) do
    body = """
    Hi #{booking.customer_name},

    Your booking is confirmed: #{service.name}, #{Format.format_range(booking)}.
    #{price_line(booking)}
    Manage or cancel: #{manage_url(booking)}
    """

    ics = ICS.booking_ics(booking, service, manage_url(booking))

    deliver(booking.customer_email, subject, body, [
      Swoosh.Attachment.new({:data, ics},
        filename: "booking.ics",
        content_type: "text/calendar"
      )
    ])
  end

  defp price_line(%Booking{total_price: nil}), do: ""

  defp price_line(%Booking{total_price: total, currency: currency}),
    do: "Total: #{PhoenixKitBookings.Pricing.format(total, currency)}\n"

  defp manage_url(booking), do: Paths.public_manage_url(Bookings.manage_token(booking))

  # Best-effort delivery: log-and-swallow every failure mode.
  defp deliver(nil, _subject, _body, _attachments), do: :ok

  defp deliver(to, subject, body, attachments) do
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@localhost")
    from_name = PhoenixKit.Settings.get_setting("from_name", "Bookings")

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(to)
      |> Swoosh.Email.from({from_name, from_email})
      |> Swoosh.Email.subject(subject)
      |> Swoosh.Email.text_body(body)

    email =
      Enum.reduce(attachments, email, &Swoosh.Email.attachment(&2, &1))

    case PhoenixKit.Mailer.deliver_email(email) do
      {:ok, _} -> :ok
      {:error, reason} -> log_failure(to, subject, reason)
    end
  rescue
    e -> log_failure(to, subject, e)
  catch
    :exit, reason -> log_failure(to, subject, reason)
  end

  defp log_failure(to, subject, reason) do
    Logger.warning(
      "[Bookings] Email #{inspect(subject)} to #{inspect(to)} failed: #{inspect(reason)}"
    )

    :error
  end
end
