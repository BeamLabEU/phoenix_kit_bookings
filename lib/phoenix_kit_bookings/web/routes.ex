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

  The `:locale` segment is unconstrained — Phoenix.Router has no segment
  constraints, and silently drops any regex option. Core keeps that safe
  with declaration order (admin / authenticated surfaces are emitted
  *before* this `generate/1` is spliced) plus the
  `:phoenix_kit_locale_validation` pipeline plug, which redirects invalid,
  disabled, and dialect URLs. Both scopes pipe through that plug; skipping
  it would 200 `/xx/bookings` and apply a disabled language code, which
  no other PhoenixKit public page does.

  These paths are specific (`/bookings`, `/book/:slug`,
  `/bookings/manage/:token`), not catch-alls, so they cannot bind
  `/<prefix>/admin/bookings` as `locale = "admin"` — that URL is already
  claimed by the admin bare route, which `phoenix_kit_routes/0` declares
  first. Do not add a catch-all here.
  """

  def generate(url_prefix) do
    extra_on_mount = Application.get_env(:phoenix_kit, :extra_live_session_on_mount, [])

    quote do
      live_session :phoenix_kit_bookings_public,
        on_mount:
          unquote(
            extra_on_mount ++
              [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}]
          ) do
        # Localized first, so `/<prefix>/et/bookings` is matched as a
        # locale rather than falling through to the bare scope.
        scope unquote(localized_scope(url_prefix)) do
          pipe_through([
            :browser,
            :phoenix_kit_auto_setup,
            :phoenix_kit_locale_validation
          ])

          unquote(public_live_routes())
        end

        scope unquote(url_prefix) do
          pipe_through([
            :browser,
            :phoenix_kit_auto_setup,
            :phoenix_kit_locale_validation
          ])

          unquote(public_live_routes())
        end
      end
    end
  end

  def public_routes(_url_prefix), do: nil

  # `scope "//:locale"` is what `"#{ "/"}/:locale"` produces. Phoenix
  # may collapse it, but root-mounted hosts (`url_prefix: "/"`) are the
  # ones core's shop/`locale="admin"` bug was measured on, so do not
  # leave that to chance.
  defp localized_scope(prefix) when prefix in ["/", ""], do: "/:locale"
  defp localized_scope(prefix), do: "#{prefix}/:locale"

  defp public_live_routes do
    quote do
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
