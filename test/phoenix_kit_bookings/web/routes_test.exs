# Built with Module.create/3 rather than a plain `defmodule` so the AST from
# `generate/1` is spliced by `unquote/1` into a block that already carries
# `use Phoenix.Router` and `import Phoenix.LiveView.Router`. Evaluating it into
# an existing module instead loses those imports and `live_session/3` is
# undefined.
#
# The three pipelines only need to exist as names: `generate/1` is expanded
# into the host router *after* `phoenix_kit_routes/0` has defined them.
host_router_body = fn prefix ->
  quote do
    use Phoenix.Router, helpers: false

    import Phoenix.LiveView.Router

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    pipeline :phoenix_kit_auto_setup do
      plug(:accepts, ["html"])
    end

    pipeline :phoenix_kit_locale_validation do
      plug(:accepts, ["html"])
    end

    unquote(PhoenixKitBookings.Web.Routes.generate(prefix))
  end
end

Module.create(
  PhoenixKitBookings.Web.RoutesTest.HostRouter,
  host_router_body.("/phoenix_kit"),
  Macro.Env.location(__ENV__)
)

Module.create(
  PhoenixKitBookings.Web.RoutesTest.RootHostRouter,
  host_router_body.("/"),
  Macro.Env.location(__ENV__)
)

defmodule PhoenixKitBookings.Web.RoutesTest do
  @moduledoc """
  Pins the URL shapes `route_module/0` emits into a host router.

  This compiles a router from `Web.Routes.generate/1` the way core's
  `phoenix_kit_routes()` does, rather than from `Test.Router` — which
  hand-writes the same paths and therefore cannot catch a change in what
  `generate/1` actually emits. That gap is how the module shipped 0.1.3
  registering only the bare shape while `Paths` produced localized links.
  """
  use ExUnit.Case, async: true

  @url_prefix "/phoenix_kit"

  alias PhoenixKitBookings.Web.Public.{BookLive, ManageLive, ServicesLive}
  alias PhoenixKitBookings.Web.RoutesTest.{HostRouter, RootHostRouter}

  defp routed?(router \\ HostRouter, path) do
    match?(%{route: _}, Phoenix.Router.route_info(router, "GET", path, "example.test"))
  end

  defp info(router \\ HostRouter, path) do
    Phoenix.Router.route_info(router, "GET", path, "example.test")
  end

  describe "generate/1" do
    test "registers every public page under the bare prefix" do
      for path <- [
            "#{@url_prefix}/bookings",
            "#{@url_prefix}/book/some-slug",
            "#{@url_prefix}/bookings/manage/some-token"
          ] do
        assert routed?(path), "expected #{path} to be routed"
      end
    end

    # The regression. `Paths` builds public links through
    # `Routes.path/1`, which inserts a locale segment as soon as the
    # Languages module is on and the target is not the prefixless default.
    # Without the localized scope those links 404 — including the manage
    # link mailed to a guest, which is their only way to cancel.
    test "registers every public page under the localized prefix too" do
      for locale <- ["et", "ru", "en"],
          path <- [
            "#{@url_prefix}/#{locale}/bookings",
            "#{@url_prefix}/#{locale}/book/some-slug",
            "#{@url_prefix}/#{locale}/bookings/manage/some-token"
          ] do
        assert routed?(path), "expected #{path} to be routed"
      end
    end

    test "both shapes reach the same LiveView in the same live_session" do
      pairs = [
        {"#{@url_prefix}/bookings", "#{@url_prefix}/et/bookings", ServicesLive},
        {"#{@url_prefix}/book/s", "#{@url_prefix}/et/book/s", BookLive},
        {"#{@url_prefix}/bookings/manage/t", "#{@url_prefix}/et/bookings/manage/t", ManageLive}
      ]

      for {bare_path, localized_path, live_view} <- pairs do
        bare = info(bare_path)
        localized = info(localized_path)

        assert %{log_module: ^live_view} = bare
        assert %{log_module: ^live_view} = localized
        assert {^live_view, _, _, %{name: :phoenix_kit_bookings_public}} = bare.phoenix_live_view

        assert {^live_view, _, _, %{name: :phoenix_kit_bookings_public}} =
                 localized.phoenix_live_view

        refute bare.route == localized.route
      end
    end

    test "both shapes pipe through locale validation" do
      for path <- ["#{@url_prefix}/bookings", "#{@url_prefix}/et/bookings"] do
        assert :phoenix_kit_locale_validation in info(path).pipe_through
      end
    end

    test "the localized scope binds :locale" do
      assert %{path_params: %{"locale" => "et", "slug" => "s"}} =
               info("#{@url_prefix}/et/book/s")

      assert %{path_params: %{"slug" => "s"}} = bare = info("#{@url_prefix}/book/s")
      refute Map.has_key?(bare.path_params, "locale")
    end

    test "does not capture unrelated paths under a locale segment" do
      refute routed?("#{@url_prefix}/et")
      refute routed?("#{@url_prefix}/et/shop")
      refute routed?("#{@url_prefix}/et/users/log-in")
    end

    test "a root-mounted host still gets both shapes" do
      assert routed?(RootHostRouter, "/bookings")
      assert routed?(RootHostRouter, "/et/bookings")
      assert routed?(RootHostRouter, "/book/s")
      assert routed?(RootHostRouter, "/et/book/s")
      assert routed?(RootHostRouter, "/bookings/manage/t")
      assert routed?(RootHostRouter, "/et/bookings/manage/t")

      assert %{log_module: BookLive} = info(RootHostRouter, "/et/book/s")
      assert :phoenix_kit_locale_validation in info(RootHostRouter, "/et/bookings").pipe_through
    end
  end
end
