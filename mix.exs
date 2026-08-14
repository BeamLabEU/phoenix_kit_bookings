defmodule PhoenixKitBookings.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_bookings"

  def project do
    [
      app: :phoenix_kit_bookings,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Universal booking module for PhoenixKit — day/night stays, fixed slots, " <>
          "and free-form reservations in one configurable model",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitBookings",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitBookings.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitBookings.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar. Unset => the published
  # pin, so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings, Scope, Activity —
      # and, since the `put_slug/3` adoption, the slug changeset glue.
      # 2.4.0+ is REQUIRED, not preferred: `Service.changeset/2` calls
      # `PhoenixKit.Utils.Slug.put_slug/3`, which does not exist before core
      # 2.4.0. Under `~> 2.0` a host could resolve core 2.0–2.3 and every
      # save touching `:name` would raise UndefinedFunctionError — in the
      # consumer's app, never in this repo's own run, because the workspace
      # always resolves the newest core. Two-segment, so every later 2.x
      # still satisfies it. Guarded by test/core_pin_conformance_test.exs.
      pk_dep(:phoenix_kit, "~> 2.4"),

      # The booking rules engine (BookingConfig / Availability / Constraints /
      # TimeSlots) and calendar UI components.
      pk_dep(:phoenix_live_calendar, "~> 0.4"),

      # LiveView is needed for the admin and public pages.
      {:phoenix_live_view, "~> 1.1"},

      # Docs
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # HTML parser for Phoenix.LiveViewTest
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitBookings",
      source_ref: "#{@version}"
    ]
  end
end
