defmodule PhoenixKitBookings.ICS do
  @moduledoc """
  Minimal iCalendar (RFC 5545) rendering for booking confirmations —
  enough for Google/Outlook/Apple to import the event from the email
  attachment. Timed bookings emit UTC datetimes; day/night bookings emit
  `VALUE=DATE` pairs (exclusive end, exactly the iCal convention).
  """

  alias PhoenixKitBookings.Schemas.{Booking, Service}

  @doc "The .ics file content for a booking."
  def booking_ics(%Booking{} = booking, %Service{} = service, manage_url) do
    now = DateTime.utc_now()

    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//PhoenixKit//Bookings//EN",
        "METHOD:PUBLISH",
        "BEGIN:VEVENT",
        "UID:#{booking.uuid}@phoenix-kit-bookings",
        "DTSTAMP:#{format_dt(now)}",
        "SUMMARY:#{escape(service.name)}",
        "STATUS:#{ical_status(booking.status)}"
      ] ++
        dt_lines(booking) ++
        [
          "DESCRIPTION:#{escape("Manage or cancel: #{manage_url}")}",
          "END:VEVENT",
          "END:VCALENDAR"
        ]

    Enum.join(lines, "\r\n") <> "\r\n"
  end

  defp dt_lines(%Booking{starts_at: %DateTime{} = starts_at} = booking) do
    ["DTSTART:#{format_dt(starts_at)}", "DTEND:#{format_dt(booking.ends_at)}"]
  end

  defp dt_lines(%Booking{starts_on: %Date{} = starts_on} = booking) do
    [
      "DTSTART;VALUE=DATE:#{format_date(starts_on)}",
      "DTEND;VALUE=DATE:#{format_date(booking.ends_on)}"
    ]
  end

  defp format_dt(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")

  defp ical_status("cancelled"), do: "CANCELLED"
  defp ical_status("pending"), do: "TENTATIVE"
  defp ical_status(_), do: "CONFIRMED"

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\n", "\\n")
  end
end
