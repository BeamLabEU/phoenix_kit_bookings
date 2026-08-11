defmodule PhoenixKitBookings.Web.Routes do
  @moduledoc """
  Public route definitions for the Bookings module.

  Admin pages are auto-generated from `PhoenixKitBookings.admin_tabs/0`;
  only the public booking surface lives here. All paths are specific (no
  catch-alls), so they belong in `generate/1` — placed early in the host
  router, they can never shadow `/admin/*`.

  The public LiveViews run in their own `live_session` with core's
  permissive `:phoenix_kit_mount_current_scope` hook — a logged-in
  visitor's scope is available (prefill, `login_required` services), an
  anonymous visitor gets a guest scope.
  """

  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_auto_setup])

        live_session :phoenix_kit_bookings_public,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live("/bookings", PhoenixKitBookings.Web.Public.ServicesLive, :index,
            as: :bookings_public_index
          )

          live("/book/:slug", PhoenixKitBookings.Web.Public.BookLive, :book,
            as: :bookings_public_book
          )

          live("/bookings/manage/:token", PhoenixKitBookings.Web.Public.ManageLive, :manage,
            as: :bookings_public_manage
          )
        end
      end
    end
  end

  def public_routes(_url_prefix), do: nil
end
