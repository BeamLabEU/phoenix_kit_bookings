defmodule PhoenixKitBookings.Web.Format do
  @moduledoc """
  Presentation helpers shared by the admin and public LiveViews: booking
  ranges in the site frame, service mode summaries, status badge classes.
  """

  alias PhoenixKitBookings.Engine
  alias PhoenixKitBookings.Schemas.{Booking, Service}

  @doc "One-line human summary of a service's booking shape."
  def mode_summary(%Service{time_unit: "night"} = s),
    do: "Nightly stays · #{stay_summary(s)} · #{s.seats} unit(s)"

  def mode_summary(%Service{time_unit: "day"} = s),
    do: "Full days · #{stay_summary(s)} · #{s.seats} unit(s)"

  def mode_summary(%Service{flexible_duration: true} = s) do
    max = if s.max_duration, do: "#{s.max_duration} min", else: "unlimited"
    "Free-form · #{s.min_duration || s.duration} min – #{max} · #{s.seats} seat(s)"
  end

  def mode_summary(%Service{} = s) do
    interval = s.slot_interval || s.duration
    "Slots · #{s.duration} min every #{interval} min · #{s.seats} seat(s)"
  end

  defp stay_summary(%Service{min_stay: min, max_stay: max}) do
    unit = "u."

    case {min || 1, max} do
      {1, nil} -> "any length"
      {min, nil} -> "min #{min} #{unit}"
      {min, max} -> "#{min}–#{max} #{unit}"
    end
  end

  @doc "Formats a booking's occupancy for lists, in the site frame."
  def format_range(%Booking{starts_at: %DateTime{} = starts_at} = booking) do
    start_f = Engine.utc_to_frame(starts_at)
    end_f = Engine.utc_to_frame(booking.ends_at)

    if DateTime.to_date(start_f) == DateTime.to_date(end_f) do
      "#{Calendar.strftime(start_f, "%d %b %Y")} · " <>
        "#{Calendar.strftime(start_f, "%H:%M")}–#{Calendar.strftime(end_f, "%H:%M")}"
    else
      "#{Calendar.strftime(start_f, "%d %b %Y %H:%M")} → " <>
        Calendar.strftime(end_f, "%d %b %Y %H:%M")
    end
  end

  def format_range(%Booking{starts_on: %Date{} = starts_on} = booking) do
    nights = Date.diff(booking.ends_on, starts_on)

    "#{Calendar.strftime(starts_on, "%d %b %Y")} → " <>
      "#{Calendar.strftime(booking.ends_on, "%d %b %Y")} (#{nights})"
  end

  def format_range(_), do: "—"

  @doc "daisyUI badge class per booking status."
  def status_badge("pending"), do: "badge badge-warning"
  def status_badge("confirmed"), do: "badge badge-success"
  def status_badge("cancelled"), do: "badge badge-ghost"
  def status_badge(_), do: "badge"

  @doc "daisyUI badge class per service status."
  def service_badge("active"), do: "badge badge-success"
  def service_badge("inactive"), do: "badge badge-warning"
  def service_badge("trashed"), do: "badge badge-error"
  def service_badge(_), do: "badge"
end
