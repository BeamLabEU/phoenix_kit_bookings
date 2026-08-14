defmodule PhoenixKitBookings.ServiceSlugTest do
  @moduledoc """
  Service slugs after adopting core's `PhoenixKit.Utils.Slug.put_slug/3`.

  The local generator it replaced slugified ASCII-only (`[^a-z0-9]` after
  downcase), so a Cyrillic or Greek name yielded "" — which then failed this
  schema's own slug format validation, and such a service could not be
  created at all. It also never probed for collisions, so two services named
  alike hit `phoenix_kit_bookings_services_slug_index` as a raw constraint
  error instead of getting a suffix.

  Exact transliteration output is deliberately not pinned: what core returns
  depends on which `phoenix_kit` resolves, and asserting version-dependent
  romanization is how phoenix_kit_dashboards#5 merged red.
  """
  use PhoenixKitBookings.DataCase, async: true

  import PhoenixKitBookings.Fixtures

  alias Ecto.Changeset
  alias PhoenixKitBookings.Schemas.Service

  defp changeset(attrs, service \\ %Service{}), do: Service.changeset(service, attrs)

  describe "generation" do
    test "a Cyrillic name now yields a valid, format-passing slug" do
      cs =
        changeset(%{
          "name" => "Массаж спины",
          "time_unit" => "minutes",
          "duration" => 60,
          "seats" => 1
        })

      assert cs.valid?

      slug = Changeset.get_change(cs, :slug)
      assert is_binary(slug) and slug != ""
      assert slug =~ ~r/^[a-z0-9][a-z0-9-]*$/
    end

    test "a Greek name yields a valid, format-passing slug" do
      cs =
        changeset(%{
          "name" => "Μασάζ πλάτης",
          "time_unit" => "minutes",
          "duration" => 60,
          "seats" => 1
        })

      assert cs.valid?

      slug = Changeset.get_change(cs, :slug)
      assert is_binary(slug) and slug != ""
      assert slug =~ ~r/^[a-z0-9][a-z0-9-]*$/
    end

    test "an explicit slug wins over the generated one" do
      cs =
        changeset(%{
          "name" => "Deep Tissue",
          "slug" => "custom-massage",
          "time_unit" => "minutes",
          "duration" => 60,
          "seats" => 1
        })

      assert cs.valid?
      assert Changeset.get_change(cs, :slug) == "custom-massage"
    end

    test "an unromanizable name does not write a blank slug" do
      # Core's slugify falls back to "" for unromanizable scripts, and
      # put_slug then leaves the changeset alone rather than storing a
      # blank for the next save to fight over. The admin form's required
      # slug is what the operator then fills in by hand.
      cs =
        changeset(%{
          "name" => "日本語",
          "time_unit" => "minutes",
          "duration" => 60,
          "seats" => 1
        })

      assert Changeset.get_change(cs, :slug) == nil
      refute cs.valid?
      assert %{slug: _} = errors_on(cs)
    end

    test "an existing slug survives a rename — get_field semantics preserved" do
      existing = %Service{name: "Old", slug: "old"}
      cs = Service.changeset(existing, %{"name" => "Brand New Name"})

      assert Changeset.get_change(cs, :slug) == nil
      assert Changeset.get_field(cs, :slug) == "old"
    end

    test "a persisted romanized service is reachable by its generated slug" do
      service = slot_service_fixture(%{"name" => "Массаж спины"})

      assert service.slug =~ ~r/^[a-z0-9][a-z0-9-]*$/

      assert PhoenixKitBookings.Services.get_active_service_by_slug(service.slug).uuid ==
               service.uuid
    end
  end

  describe "uniqueness" do
    test "a name collision suffixes -2 instead of a constraint error" do
      slot_service_fixture(%{"name" => "Deep Tissue"})

      second = slot_service_fixture(%{"name" => "Deep Tissue"})

      assert second.slug == "deep-tissue-2"
    end

    test "the suffix stays inside the 160-character cap" do
      long = String.duplicate("a", 200)
      first = slot_service_fixture(%{"name" => long})
      second = slot_service_fixture(%{"name" => long})

      assert String.length(first.slug) == 160
      assert String.ends_with?(second.slug, "-2")
      assert String.length(second.slug) == 160
    end
  end
end
