defmodule PhoenixKitBookings.Notifier do
  @moduledoc """
  Transactional email for the booking lifecycle, via core's
  `PhoenixKit.Mailer` (routes through Integrations → parent mailer →
  built-in, honors the blocklist). Every send is best-effort — a mail
  failure must never fail the booking operation (the newsletters worker
  convention). Confirmation emails attach an `.ics` calendar file.
  """

  use Gettext, backend: PhoenixKitBookings.Gettext

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBookings.{Bookings, ICS, Paths}
  alias PhoenixKitBookings.Schemas.{Booking, Service, WaitlistEntry}
  alias PhoenixKitBookings.Web.Format

  @doc "Right email for a fresh booking (confirmed vs pending-approval)."
  def booking_created(%Booking{status: "pending"} = booking, %Service{} = service) do
    deliver(
      booking.customer_email,
      gettext("Booking request received — %{service}", service: service.name),
      greeting(booking) <>
        "\n\n" <>
        gettext(
          "Your request for %{service} (%{when}) has been received and is waiting for approval. You'll get another email once it's decided.",
          service: service.name,
          when: Format.format_range(booking)
        ) <>
        "\n\n" <> manage_line(booking),
      []
    )
  end

  def booking_created(%Booking{} = booking, %Service{} = service) do
    confirmation(
      booking,
      service,
      gettext("Booking confirmed — %{service}", service: service.name)
    )
  end

  @doc "Pending → confirmed (approval granted)."
  def booking_confirmed(%Booking{} = booking, %Service{} = service) do
    confirmation(
      booking,
      service,
      gettext("Booking approved — %{service}", service: service.name)
    )
  end

  def booking_cancelled(%Booking{} = booking, %Service{} = service) do
    deliver(
      booking.customer_email,
      gettext("Booking cancelled — %{service}", service: service.name),
      greeting(booking) <>
        "\n\n" <>
        gettext("Your booking for %{service} (%{when}) has been cancelled.",
          service: service.name,
          when: Format.format_range(booking)
        ) <>
        "\n\n" <>
        gettext("Book again: %{url}", url: Paths.public_book_url(service.slug)) <> "\n",
      []
    )
  end

  def reminder(%Booking{} = booking, %Service{} = service) do
    deliver(
      booking.customer_email,
      gettext("Reminder — %{service} %{when}",
        service: service.name,
        when: Format.format_range(booking)
      ),
      greeting(booking) <>
        "\n\n" <>
        gettext("A reminder about your upcoming booking: %{service}, %{when}.",
          service: service.name,
          when: Format.format_range(booking)
        ) <>
        "\n\n" <> manage_line(booking),
      []
    )
  end

  @doc "A cancellation freed capacity on a date this entry waits for."
  def waitlist_opening(%WaitlistEntry{} = entry, %Service{} = service, %Date{} = date) do
    deliver(
      entry.customer_email,
      gettext("A spot opened up — %{service}", service: service.name),
      gettext("Hi %{name},", name: entry.customer_name) <>
        "\n\n" <>
        gettext(
          "Availability just opened up for %{service} on %{date}. First come, first served:",
          service: service.name,
          date: Calendar.strftime(date, "%d.%m.%Y")
        ) <>
        "\n\n" <> Paths.public_book_url(service.slug) <> "\n",
      []
    )
  end

  @doc """
  Tells the service's owner that a booking landed in somebody else's regular
  slot. Goes to the owning user's address, else the `bookings_notify_email`
  setting; with neither, nobody is mailed (the booking still carries the
  flag and the activity log has it).
  """
  def regular_slot_conflict(%Booking{} = booking, %Service{} = service, conflicts) do
    holders =
      Enum.map_join(conflicts, ", ", fn c ->
        c["holder_name"] || c["holder_email"] || gettext("a regular customer")
      end)

    deliver(
      owner_email(service),
      gettext("Regular slot booked by someone else — %{service}", service: service.name),
      gettext("%{customer} (%{email}) booked %{service}, %{when}.",
        customer: booking.customer_name || gettext("Someone"),
        email: booking.customer_email || gettext("no email"),
        service: service.name,
        when: Format.format_range(booking)
      ) <>
        "\n\n" <>
        gettext(
          "That time usually belongs to %{holders}. The booking was accepted; check whether the regular customer needs to hear about it.",
          holders: holders
        ) <>
        "\n\n" <>
        gettext("Reservations: %{url}", url: Paths.admin_reservations_url()) <> "\n",
      []
    )
  end

  defp owner_email(%Service{owner_uuid: owner_uuid}) when is_binary(owner_uuid) do
    case Auth.get_user(owner_uuid) do
      %{email: email} when is_binary(email) -> email
      _ -> notify_email()
    end
  rescue
    _ -> notify_email()
  end

  defp owner_email(_service), do: notify_email()

  defp notify_email do
    case PhoenixKit.Settings.get_setting("bookings_notify_email", "") do
      email when is_binary(email) and email != "" -> email
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp greeting(booking), do: gettext("Hi %{name},", name: booking.customer_name)

  defp manage_line(booking),
    do: gettext("Manage or cancel: %{url}", url: manage_url(booking)) <> "\n"

  defp confirmation(booking, service, subject) do
    body =
      greeting(booking) <>
        "\n\n" <>
        gettext("Your booking is confirmed: %{service}, %{when}.",
          service: service.name,
          when: Format.format_range(booking)
        ) <>
        "\n" <> price_line(booking) <> "\n" <> manage_line(booking)

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
    do:
      gettext("Total: %{total}", total: PhoenixKitBookings.Pricing.format(total, currency)) <>
        "\n"

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
