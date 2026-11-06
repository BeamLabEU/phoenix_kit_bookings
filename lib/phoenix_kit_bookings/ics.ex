defmodule PhoenixKitBookings.ICS do
  @moduledoc """
  Minimal iCalendar (RFC 5545) rendering for booking confirmations —
  enough for Google/Outlook/Apple to import the event from the email
  attachment. Timed bookings emit UTC datetimes; day/night bookings emit
  `VALUE=DATE` pairs (exclusive end, exactly the iCal convention).
  """

  alias PhoenixKitBookings.Schemas.{Booking, Service}

  @max_line_octets 75

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

    lines |> Enum.flat_map(&fold/1) |> Enum.join("\r\n") |> Kernel.<>("\r\n")
  end

  # RFC 5545 §3.1: a line stops at 75 octets and goes on after CRLF and a space.
  # A manage URL alone is longer. Folded between code points, never inside one.
  defp fold(line) do
    {lines, last} =
      line
      |> String.codepoints()
      |> Enum.reduce({[], ""}, fn point, {lines, current} ->
        if byte_size(current) + byte_size(point) > @max_line_octets,
          do: {[current | lines], " " <> point},
          else: {lines, current <> point}
      end)

    Enum.reverse([last | lines])
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
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\\n")
  end
end
