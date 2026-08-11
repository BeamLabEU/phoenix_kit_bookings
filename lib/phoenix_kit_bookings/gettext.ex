defmodule PhoenixKitBookings.Gettext do
  @moduledoc """
  Module-owned gettext backend for Bookings **domain** strings (hybrid
  convention: generic strings already translated workspace-wide stay on
  core's `PhoenixKitWeb.Gettext`).
  """

  use Gettext.Backend, otp_app: :phoenix_kit_bookings
end
