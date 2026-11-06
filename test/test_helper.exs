# Test helper for PhoenixKitBookings test suite.
#
# Level 1: Unit tests (schemas, changesets, pure engine functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable (`:integration` tag).
#
# To enable integration tests:
#
#     mix test.setup           # createdb + migrate
#     mix test

support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "schema_migration.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "fixtures.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_bookings, PhoenixKitBookings.Test.Repo)[:database] ||
    "phoenix_kit_bookings_test"

# One classified connection attempt, with the repo's OWN credentials and
# transport, before anything starts the pool. An unreachable database is the one
# case that excludes the integration tests: the unit tests still run.
db_reachable =
  case PhoenixKit.TestSupport.PostgresPreflight.check(
         Application.get_env(:phoenix_kit_bookings, PhoenixKitBookings.Test.Repo, [])
       ) do
    :ok ->
      true

    {:error, _reason, message} ->
      IO.puts(:stderr, "\n" <> message)
      false
  end

# A database that answers and then cannot be built stops the run here, rather
# than excluding the suite and passing with nothing tested. A test database
# behind core's floor needs `mix test.reset`; core's error says so.
repo_available =
  if db_reachable do
    {:ok, _} = PhoenixKitBookings.Test.Repo.start_link()

    # Build core's tables (settings, activities, users, uuid_generate_v7())
    # by running phoenix_kit's own versioned migrations directly.
    PhoenixKit.Migration.ensure_current(PhoenixKitBookings.Test.Repo, log: false)

    # This module's own tables aren't part of core's migration chain (see
    # `migration_module/0` on `PhoenixKitBookings`) — apply them the same
    # way `mix phoenix_kit.update` would in a real host app.
    Ecto.Migrator.run(
      PhoenixKitBookings.Test.Repo,
      [
        {1, PhoenixKitBookings.Test.SchemaMigration},
        {2, PhoenixKitBookings.Test.SchemaMigrationV2}
      ],
      :up,
      all: true,
      log: false
    )

    # Enable the module BEFORE sandbox mode so the row commits for every
    # test — `Scope.can?/2` gates on module enablement, so Policy checks
    # would otherwise fail closed across the whole suite.
    PhoenixKit.Settings.update_boolean_setting_with_module(
      "bookings_enabled",
      true,
      "bookings"
    )

    Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitBookings.Test.Repo, :manual)
    true
  else
    IO.puts("""
    \n⚠  Cannot reach test database "#{db_name}" — integration tests will be excluded.
       The reason is printed above.
    """)

    false
  end

Application.put_env(:phoenix_kit_bookings, :test_repo_available, repo_available)

# Start minimal PhoenixKit services so the module's runtime dependencies
# (PubSub topics, ModuleRegistry, the rate limiter) resolve during tests.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to "/" for tests so Paths helpers
# produce paths the test router can match.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

if repo_available do
  {:ok, _} = PhoenixKitBookings.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
