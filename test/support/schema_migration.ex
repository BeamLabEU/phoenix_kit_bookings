defmodule PhoenixKitBookings.Test.SchemaMigration do
  @moduledoc """
  Thin `Ecto.Migration` wrapper that runs
  `PhoenixKitBookings.Migrations.Schema` against the test repo.

  `Schema.up/1` uses `Ecto.Migration`'s `execute/1`, which only works
  inside an active `Ecto.Migration.Runner`. In production,
  `mix phoenix_kit.update` generates exactly this kind of wrapper as a
  real migration file under the host app's `priv/repo/migrations/`;
  `test_helper.exs` runs this one in-memory via `Ecto.Migrator.run/4`.
  """

  use Ecto.Migration

  alias PhoenixKitBookings.Migrations.Schema

  def up, do: Schema.up(prefix: "public")
  def down, do: Schema.down(prefix: "public")
end
