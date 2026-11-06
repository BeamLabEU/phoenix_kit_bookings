import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   mix test.setup       # createdb + migrate
config :phoenix_kit_bookings, ecto_repos: [PhoenixKitBookings.Test.Repo]

# `PGDATABASE` points this suite at another database, for a shared instance or
# one the test role cannot create. Unset, it is the name CI provisions.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_bookings_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

# `PGPOOL` bounds the pool: the default opens dozens of connections on a
# many-core box, which a shared instance near its ceiling cannot spare.
pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_bookings, PhoenixKitBookings.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool,
  priv: "test/support/postgres"

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
# The endpoint powers Phoenix.Token signing (guest manage tokens).
config :phoenix_kit,
  repo: PhoenixKitBookings.Test.Repo,
  endpoint: PhoenixKitBookings.Test.Endpoint,
  # Route LayoutWrapper.app_layout through a minimal test layout — the
  # fallback (core's own root layout) needs core's endpoint started.
  layout: {PhoenixKitBookings.Test.Layouts, :public}

# Test Endpoint for LiveView tests. `phoenix_kit_bookings` has no endpoint of
# its own in production — the host app provides one — so this endpoint only
# exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_bookings, PhoenixKitBookings.Test.Endpoint,
  secret_key_base: String.duplicate("b", 64),
  live_view: [signing_salt: "bookings-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitBookings.Test.Layouts]]

# Capture Notifier emails in the test process (Swoosh test adapter).
config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Test

config :phoenix, :json_library, Jason

config :logger, level: :warning
