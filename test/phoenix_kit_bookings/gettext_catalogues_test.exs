defmodule PhoenixKitBookings.GettextCataloguesTest do
  @moduledoc """
  The module's own et/ru catalogues are complete: every msgid of the template
  has a non-empty, non-fuzzy translation that keeps its placeholders, and the
  backend actually serves them.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitBookings.Errors
  alias PhoenixKitBookings.Web.Components.AvailabilityCalendar
  alias PhoenixKitBookings.Web.Format

  @shipped ~w(et ru)
  @root Path.expand("../../priv/gettext", __DIR__)

  defp messages(path) do
    {:ok, po} = Expo.PO.parse_file(path)
    po.messages
  end

  defp placeholders(text), do: ~r/%\{\w+\}/ |> Regex.scan(text) |> List.flatten() |> MapSet.new()

  for lang <- @shipped do
    test "#{lang}: every template message is translated, none fuzzy, placeholders kept" do
      template = messages(Path.join(@root, "default.pot"))
      catalogue = messages(Path.join(@root, "#{unquote(lang)}/LC_MESSAGES/default.po"))

      by_key = Map.new(catalogue, &{Expo.Message.key(&1), &1})

      for message <- template do
        key = Expo.Message.key(message)
        translated = Map.fetch!(by_key, key)
        refute Expo.Message.has_flag?(translated, "fuzzy"), "fuzzy: #{inspect(key)}"

        msgid = IO.iodata_to_binary(message.msgid)

        strings =
          case translated do
            %Expo.Message.Singular{msgstr: s} -> [IO.iodata_to_binary(s)]
            %Expo.Message.Plural{msgstr: m} -> Enum.map(Map.values(m), &IO.iodata_to_binary/1)
          end

        for string <- strings do
          assert string != "", "untranslated: #{inspect(key)}"

          assert MapSet.subset?(
                   placeholders(string),
                   MapSet.put(placeholders(msgid), "%{count}")
                 ),
                 "placeholder changed in #{inspect(key)}: #{string}"
        end
      end
    end
  end

  test "the backend serves the catalogues" do
    assert Gettext.with_locale(PhoenixKitBookings.Gettext, "et", fn ->
             Errors.message(:overlap)
           end) == "See aeg broneeriti just ära. Vali mõni teine."

    assert Gettext.with_locale(PhoenixKitBookings.Gettext, "ru", fn ->
             Errors.message(:at_capacity)
           end) =~ "занято"
  end

  test "dates use translated month names" do
    assert Gettext.with_locale(PhoenixKitBookings.Gettext, "ru", fn ->
             Format.strftime(~D[2026-05-03], "%d %b %Y")
           end) == "03 мая 2026"
  end

  test "components render in the page's language" do
    html =
      Gettext.with_locale(PhoenixKitBookings.Gettext, "et", fn ->
        render_component(&AvailabilityCalendar.month/1,
          id: "cal",
          month: ~D[2026-12-01],
          statuses: %{~D[2026-12-02] => :partial}
        )
      end)

    assert html =~ "detsember 2026"
    assert html =~ "Osaliselt broneeritud"
  end

  test "the tabs translate through the module's backend" do
    for tab <- PhoenixKitBookings.admin_tabs() do
      assert tab.gettext_backend == PhoenixKitBookings.Gettext
    end

    assert "Reservations" in PhoenixKitBookings.translatable_labels()
  end
end
