defmodule PhoenixKitBookings.DataCase do
  @moduledoc """
  Test case for tests requiring database access. Tagged `:integration`,
  auto-excluded when the test DB is unavailable.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitBookings.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitBookings.DataCase
      import PhoenixKitBookings.Fixtures
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBookings.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc "Translates changeset errors into a `%{field => [message]}` map."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
