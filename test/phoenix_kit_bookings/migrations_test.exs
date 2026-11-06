defmodule PhoenixKitBookings.MigrationsTest do
  @moduledoc """
  The chain's version marker and V2's column, against the migrated test
  database.
  """
  use PhoenixKitBookings.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitBookings.Migrations.Schema
  alias PhoenixKitBookings.Test.Repo

  test "current_version is 2 and the database reads it back from the marker" do
    assert Schema.current_version() == 2
    assert Schema.migrated_version_runtime(prefix: "public") == 2
  end

  test "a marker-less services table reads as V1, a missing one as 0" do
    Repo.query!("COMMENT ON TABLE public.phoenix_kit_bookings_services IS NULL")
    assert Schema.migrated_version_runtime(prefix: "public") == 1

    Repo.query!("COMMENT ON TABLE public.phoenix_kit_bookings_services IS 'bookings_schema:2'")
    assert Schema.migrated_version_runtime(prefix: "public") == 2

    assert Schema.migrated_version_runtime(prefix: "no_such_schema") == 0
  end

  test "V2: bookings.time_zone exists, nullable, varchar(64)" do
    %{rows: [[data_type, max_len, is_nullable]]} =
      Repo.query!("""
      SELECT data_type, character_maximum_length, is_nullable FROM information_schema.columns
      WHERE table_name = 'phoenix_kit_bookings_bookings' AND column_name = 'time_zone'
      """)

    assert data_type == "character varying"
    assert max_len == 64
    assert is_nullable == "YES"
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
