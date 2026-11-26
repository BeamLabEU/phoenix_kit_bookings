defmodule PhoenixKitBookings.Web.Format do
  @moduledoc """
  Presentation helpers shared by the admin and public LiveViews: booking
  ranges in the site frame, service mode summaries, status badge classes.
  """

  use Gettext, backend: PhoenixKitBookings.Gettext

  alias PhoenixKitBookings.Engine
  alias PhoenixKitBookings.Schemas.{Booking, Service}

  @doc "One-line human summary of a service's booking shape."
  def mode_summary(%Service{time_unit: "night"} = s) do
    gettext("Nightly stays · %{stay} · %{units}",
      stay: stay_summary(s),
      units: ngettext("%{count} unit", "%{count} units", s.seats)
    )
  end

  def mode_summary(%Service{time_unit: "day"} = s) do
    gettext("Full days · %{stay} · %{units}",
      stay: stay_summary(s),
      units: ngettext("%{count} unit", "%{count} units", s.seats)
    )
  end

  def mode_summary(%Service{flexible_duration: true} = s) do
    max =
      if s.max_duration,
        do: gettext("%{count} min", count: s.max_duration),
        else: gettext("unlimited")

    gettext("Free-form · %{min} min – %{max} · %{seats}",
      min: s.min_duration || s.duration,
      max: max,
      seats: ngettext("%{count} seat", "%{count} seats", s.seats)
    )
  end

  def mode_summary(%Service{} = s) do
    gettext("Slots · %{duration} min every %{interval} min · %{seats}",
      duration: s.duration,
      interval: s.slot_interval || s.duration,
      seats: ngettext("%{count} seat", "%{count} seats", s.seats)
    )
  end

  defp stay_summary(%Service{min_stay: min, max_stay: max}) do
    case {min || 1, max} do
      {1, nil} -> gettext("any length")
      {min, nil} -> gettext("at least %{min}", min: min)
      {min, max} -> gettext("%{min}–%{max}", min: min, max: max)
    end
  end

  @doc """
  `Calendar.strftime/3` with the month abbreviations (`%b`) in the page's
  language.
  """
  def strftime(value, format),
    do: Calendar.strftime(value, format, abbreviated_month_names: &month_abbr/1)

  defp month_abbr(1), do: gettext("Jan")
  defp month_abbr(2), do: gettext("Feb")
  defp month_abbr(3), do: gettext("Mar")
  defp month_abbr(4), do: gettext("Apr")
  defp month_abbr(5), do: pgettext("month abbreviation", "May")
  defp month_abbr(6), do: gettext("Jun")
  defp month_abbr(7), do: gettext("Jul")
  defp month_abbr(8), do: gettext("Aug")
  defp month_abbr(9), do: gettext("Sep")
  defp month_abbr(10), do: gettext("Oct")
  defp month_abbr(11), do: gettext("Nov")
  defp month_abbr(12), do: gettext("Dec")

  @doc "Formats a booking's occupancy for lists, in the site frame."
  def format_range(%Booking{starts_at: %DateTime{} = starts_at} = booking) do
    start_f = Engine.utc_to_frame(starts_at)
    end_f = Engine.utc_to_frame(booking.ends_at)

    if DateTime.to_date(start_f) == DateTime.to_date(end_f) do
      "#{strftime(start_f, "%d %b %Y")} · " <>
        "#{strftime(start_f, "%H:%M")}–#{strftime(end_f, "%H:%M")}"
    else
      "#{strftime(start_f, "%d %b %Y %H:%M")} → " <>
        strftime(end_f, "%d %b %Y %H:%M")
    end
  end

  def format_range(%Booking{starts_on: %Date{} = starts_on} = booking) do
    nights = Date.diff(booking.ends_on, starts_on)

    "#{strftime(starts_on, "%d %b %Y")} → " <>
      "#{strftime(booking.ends_on, "%d %b %Y")} (#{nights})"
  end

  def format_range(_), do: "—"

  @doc "An instant as a site-frame date and time (\"26 Nov 2026 14:05\")."
  def format_instant(%DateTime{} = dt),
    do: dt |> Engine.utc_to_frame() |> strftime("%d %b %Y %H:%M")

  def format_instant(_), do: "—"

  @doc "The site-frame date of an instant."
  def frame_date(%DateTime{} = dt), do: dt |> Engine.utc_to_frame() |> DateTime.to_date()

  @doc "A booking status in words."
  def status_label("pending"), do: gettext("pending")
  def status_label("confirmed"), do: gettext("confirmed")
  def status_label("cancelled"), do: gettext("cancelled")
  def status_label(other), do: other

  @doc "daisyUI badge class per booking status."
  def status_badge("pending"), do: "badge badge-warning"
  def status_badge("confirmed"), do: "badge badge-success"
  def status_badge("cancelled"), do: "badge badge-ghost"
  def status_badge(_), do: "badge"

  @doc "A service status in words."
  def service_status_label("active"), do: gettext("active")
  def service_status_label("inactive"), do: gettext("inactive")
  def service_status_label("trashed"), do: gettext("trashed")
  def service_status_label(other), do: other

  @doc "daisyUI badge class per service status."
  def service_badge("active"), do: "badge badge-success"
  def service_badge("inactive"), do: "badge badge-warning"
  def service_badge("trashed"), do: "badge badge-error"
  def service_badge(_), do: "badge"
end
