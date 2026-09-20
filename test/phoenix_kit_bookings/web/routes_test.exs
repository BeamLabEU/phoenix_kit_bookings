# Built with Module.create/3 rather than a plain `defmodule` so the AST from
# `generate/1` is spliced by `unquote/1` into a block that already carries
# `use Phoenix.Router` and `import Phoenix.LiveView.Router`. Evaluating it into
# an existing module instead loses those imports and `live_session/3` is
# undefined.
Module.create(
  PhoenixKitBookings.Web.RoutesTest.HostRouter,
  quote do
    use Phoenix.Router, helpers: false

    import Phoenix.LiveView.Router

    # A host's `:browser` pipeline and core's auto-setup plug; the routes
    # only need these names to exist.
    pipeline :browser do
      plug(:accepts, ["html"])
    end

    pipeline :phoenix_kit_auto_setup do
      plug(:accepts, ["html"])
    end

    unquote(PhoenixKitBookings.Web.Routes.generate("/phoenix_kit"))
  end,
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

  alias PhoenixKitBookings.Web.RoutesTest.HostRouter

  defp routed?(path) do
    match?(%{route: _}, Phoenix.Router.route_info(HostRouter, "GET", path, "example.test"))
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

    test "both shapes reach the same LiveView" do
      %{route: bare} = Phoenix.Router.route_info(HostRouter, "GET", "#{@url_prefix}/book/s", "t")

      %{route: localized} =
        Phoenix.Router.route_info(HostRouter, "GET", "#{@url_prefix}/et/book/s", "t")

      refute bare == localized
      assert routed?("#{@url_prefix}/book/s") and routed?("#{@url_prefix}/et/book/s")
    end
  end
end
