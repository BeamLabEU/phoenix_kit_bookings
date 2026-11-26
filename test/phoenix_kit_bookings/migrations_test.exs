defmodule PhoenixKitBookings.MigrationsTest do
  @moduledoc """
  The chain's version marker and V2's column, against the migrated test
  database.
  """
  use PhoenixKitBookings.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitBookings.Migrations.Schema
  alias PhoenixKitBookings.Test.Repo

  test "current_version is 3 and the database reads it back from the marker" do
    assert Schema.current_version() == 3
    assert Schema.migrated_version_runtime(prefix: "public") == 3
  end

  test "a marker-less services table reads as V1, a missing one as 0" do
    Repo.query!("COMMENT ON TABLE public.phoenix_kit_bookings_services IS NULL")
    assert Schema.migrated_version_runtime(prefix: "public") == 1

    Repo.query!("COMMENT ON TABLE public.phoenix_kit_bookings_services IS 'bookings_schema:3'")
    assert Schema.migrated_version_runtime(prefix: "public") == 3

    assert Schema.migrated_version_runtime(prefix: "no_such_schema") == 0
  end

  test "V2: bookings.time_zone exists, nullable, varchar(64)" do
    %{rows: [[data_type, max_len, is_nullable]]} =
      Repo.query!("""
      SELECT data_type, character_maximum_length, is_nullable FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_bookings_bookings'
        AND column_name = 'time_zone'
      """)

    assert data_type == "character varying"
    assert max_len == 64
    assert is_nullable == "YES"
  end

  defp column(table, column) do
    Repo.query!(
      """
      SELECT data_type, is_nullable FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
      """,
      [table, column]
    ).rows
  end

  defp index?(name) do
    %{rows: [[found]]} =
      Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["public." <> name])

    found
  end

  test "V3: import refs on bookings and rules, each with a unique external index" do
    assert [["character varying", "YES"]] =
             column("phoenix_kit_bookings_bookings", "external_source")

    assert [["character varying", "YES"]] = column("phoenix_kit_bookings_bookings", "external_id")

    assert [["character varying", "NO"]] =
             column("phoenix_kit_bookings_availability_rules", "source")

    assert [["character varying", "YES"]] =
             column("phoenix_kit_bookings_availability_rules", "external_id")

    assert index?("phoenix_kit_bookings_bookings_external_index")
    assert index?("phoenix_kit_bookings_availability_rules_external_index")

    %{rows: [[unique?]]} =
      Repo.query!("""
      SELECT indisunique FROM pg_index
      WHERE indexrelid = 'public.phoenix_kit_bookings_bookings_external_index'::regclass
      """)

    assert unique?
  end

  test "V3: customer columns are nullable, but only an import may leave them empty" do
    assert [["character varying", "YES"]] =
             column("phoenix_kit_bookings_bookings", "customer_name")

    %{rows: [[definition]]} =
      Repo.query!("""
      SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
      JOIN pg_namespace n ON n.oid = c.connamespace
      WHERE n.nspname = 'public' AND c.conname = 'bookings_customer_required'
      """)

    assert definition =~ "import"
  end

  test "V3: services gain host_ref (indexed), bookable_online (default true) and the feed columns" do
    assert [["character varying", "YES"]] = column("phoenix_kit_bookings_services", "host_ref")
    assert [["boolean", "NO"]] = column("phoenix_kit_bookings_services", "bookable_online")
    assert [["text", "YES"]] = column("phoenix_kit_bookings_services", "ical_url")
    assert [["uuid", "YES"]] = column("phoenix_kit_bookings_services", "host_profile_uuid")
    assert index?("phoenix_kit_bookings_services_host_ref_index")
  end

  test "V3: the new tables exist" do
    for table <- ~w(price_options host_profiles events regular_slots) do
      assert index?("phoenix_kit_bookings_" <> table), table
    end
  end

  defmodule DownToV2 do
    use Ecto.Migration
    def up, do: Schema.down(prefix: "public", version: 2)
    def down, do: :ok
  end

  defmodule UpAgain do
    use Ecto.Migration
    def up, do: Schema.up(prefix: "public")
    def down, do: :ok
  end

  test "down to V2 drops what V3 added, and up again restores it" do
    Runner.run(Repo, [], 99_002, DownToV2, :forward, :up, :up, log: false)

    assert Schema.migrated_version_runtime(prefix: "public") == 2
    assert column("phoenix_kit_bookings_bookings", "external_id") == []
    assert column("phoenix_kit_bookings_services", "host_ref") == []
    refute index?("phoenix_kit_bookings_events")

    assert [["character varying", "NO"]] =
             column("phoenix_kit_bookings_bookings", "customer_name")

    assert [["character varying", "YES"]] = column("phoenix_kit_bookings_bookings", "time_zone")

    Runner.run(Repo, [], 99_003, UpAgain, :forward, :up, :up, log: false)

    assert Schema.migrated_version_runtime(prefix: "public") == 3
    assert index?("phoenix_kit_bookings_events")
  end

  test "an invalid prefix raises instead of reading as not installed" do
    assert_raise ArgumentError, fn -> Schema.migrated_version_runtime(prefix: "x; DROP") end
  end

  defmodule DownToCurrent do
    use Ecto.Migration
    def up, do: Schema.down(version: Schema.current_version())
    def down, do: :ok
  end

  test "down to the version already applied changes nothing" do
    Runner.run(Repo, [], 99_001, DownToCurrent, :forward, :up, :up, log: false)

    assert %{rows: [["time_zone"]]} =
             Repo.query!("""
             SELECT column_name FROM information_schema.columns
             WHERE table_name = 'phoenix_kit_bookings_bookings' AND column_name = 'time_zone'
             """)

    assert Schema.migrated_version_runtime(prefix: "public") == Schema.current_version()
  end
end
