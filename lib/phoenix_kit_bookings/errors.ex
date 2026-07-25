defmodule PhoenixKitBookings.Errors do
  @moduledoc """
  Maps engine/context error atoms to user-facing messages in one place,
  so LiveViews never show a raw atom or an internal engine string.
  """

  use Gettext, backend: PhoenixKitBookings.Gettext

  @doc "User-facing message for an engine/context rejection reason."
  def message(reason, context \\ %{})

  def message(:invalid_range, _), do: gettext("The selected times are not valid.")
  def message(:too_short, %{min: min}), do: gettext("Minimum length is %{min}.", min: min)
  def message(:too_short, _), do: gettext("The selected time is too short.")
  def message(:too_long, %{max: max}), do: gettext("Maximum length is %{max}.", max: max)
  def message(:too_long, _), do: gettext("The selected time is too long.")
  def message(:in_past, _), do: gettext("That time is in the past.")

  def message(:insufficient_notice, _),
    do: gettext("That time is too soon — more advance notice is required.")

  def message(:too_far_ahead, _), do: gettext("That date is too far in the future.")

  def message(:outside_availability, _),
    do: gettext("The selected time falls outside opening hours.")

  def message(:overlap, _), do: gettext("That time was just taken. Please pick another.")
  def message(:at_capacity, _), do: gettext("That time is fully booked. Please pick another.")
  def message(:login_required, _), do: gettext("Please log in to book this service.")

  def message(:service_unavailable, _),
    do: gettext("This service is not currently taking bookings.")

  def message(:not_cancellable, _), do: gettext("This booking has already been cancelled.")
  def message(_, _), do: gettext("Something went wrong. Please try again.")
end
