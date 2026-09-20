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

  ## Both URL shapes are emitted, and that is load-bearing

  Every path is registered twice inside the one `live_session`: once under
  `<prefix>/:locale` and once bare under `<prefix>`. This mirrors core's
  own `build_live_surface/5`, and it exists because
  `PhoenixKitBookings.Paths` builds every public link through
  `PhoenixKit.Utils.Routes.path/1`, which adds a locale segment as soon as
  the Languages module is enabled and the target is not the prefixless
  default. Registering only the bare shape made the module's own links
  404 the moment a host turned Languages on — including
  `public_book_url/1` and `public_manage_url/1`, which are what a guest
  gets emailed, so the self-service cancel link in a confirmation email
  died with it.

  Both shapes share one `live_session` so a front-end locale switch stays
  on the WebSocket instead of crossing a session boundary. Duplicate `:as`
  names across the two scopes are fine: hosts compile the router with
  `helpers: false`, which is the same assumption core makes.
  """

  def generate(url_prefix) do
    quote do
      live_session :phoenix_kit_bookings_public,
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
        # Localized first, so `/<prefix>/et/bookings` is matched as a
        # locale rather than falling through to the bare scope.
        scope "#{unquote(url_prefix)}/:locale" do
          pipe_through([:browser, :phoenix_kit_auto_setup])

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

        scope unquote(url_prefix) do
          pipe_through([:browser, :phoenix_kit_auto_setup])

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
