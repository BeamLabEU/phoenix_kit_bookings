defmodule PhoenixKitBookings.SchemaPrefixConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support: every
  table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries
  target the schema core's migrations installed into. A schema missing
  it silently falls back to `search_path` resolution — invisible on
  public installs, broken on prefixed ones.
  """

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        content = File.read!(path)

        String.contains?(content, ~s[schema "phoenix_kit]) and
          not String.contains?(content, "use PhoenixKit.SchemaPrefix")
      end)

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end

  # The DDL half of the same support, which the runtime check above cannot
  # see. Core installs `uuid_generate_v7()` into the schema it migrated into,
  # so a BARE call in a column default resolves through `search_path` — which
  # does not carry a named schema — and the CREATE TABLE fails outright. It
  # works on every public install, which is why it survives review.
  test "no migration statement calls uuid_generate_v7() unqualified" do
    # Comment lines dropped first: the prose around the fix has to be free to
    # name the thing it is about, and matching against it fails on a remark.
    bare =
      "lib/phoenix_kit_bookings/migrations/schema.ex"
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
      |> Enum.filter(&Regex.match?(~r/(?<!\.)(?<!\})uuid_generate_v7\(\)/, &1))

    assert bare == [],
           """
           Unqualified `uuid_generate_v7()` in the migration:

           #{Enum.join(bare, "\n")}

           Qualify it with the prefix — a bare call breaks every named-schema
           (`--prefix`) install, and works everywhere else, so it survives review.
           """
  end

  test "the migration refuses a prefix that cannot be safely interpolated" do
    alias PhoenixKitBookings.Migrations.Schema

    # `nil` is absent, not hostile — it means "public" and is left alone.
    for bad <- ["public\"; DROP TABLE x; --", "1st", "a-b", ""] do
      assert_raise ArgumentError, fn -> Schema.up(prefix: bad) end
    end
  end
end
