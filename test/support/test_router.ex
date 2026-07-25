defmodule PhoenixKitBookings.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitBookings.Paths` (admin paths get the default
  "en" locale prefix; public paths are bare).
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitBookings.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/bookings", PhoenixKitBookings.Web.Admin do
    pipe_through(:browser)

    live_session :bookings_admin_test,
      layout: {PhoenixKitBookings.Test.Layouts, :app},
      on_mount: {PhoenixKitBookings.Test.Hooks, :assign_scope} do
      live("/reservations", BookingsLive, :index)
      live("/services", ServicesLive, :index)
      live("/services/new", ServiceFormLive, :new)
      live("/services/:uuid/edit", ServiceFormLive, :edit)
    end
  end

  scope "/en/admin/settings", PhoenixKitBookings.Web.Admin do
    pipe_through(:browser)

    live_session :bookings_settings_test,
      layout: {PhoenixKitBookings.Test.Layouts, :app},
      on_mount: {PhoenixKitBookings.Test.Hooks, :assign_scope} do
      live("/bookings", SettingsLive, :index)
    end
  end

  scope "/", PhoenixKitBookings.Web.Public do
    pipe_through(:browser)

    live_session :bookings_public_test,
      layout: {PhoenixKitBookings.Test.Layouts, :app},
      on_mount: {PhoenixKitBookings.Test.Hooks, :assign_scope} do
      live("/bookings", ServicesLive, :index)
      live("/book/:slug", BookLive, :book)
      live("/bookings/manage/:token", ManageLive, :manage)
    end
  end
end
