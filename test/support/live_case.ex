defmodule PhoenixKitBookings.LiveCase do
  @moduledoc """
  Test case for LiveView tests: wires the test Endpoint, imports
  `Phoenix.LiveViewTest`, sets up the SQL sandbox, and provides
  `fake_scope/1` + `put_test_scope/2` for admin-scope mounting.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitBookings.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitBookings.LiveCase
      import PhoenixKitBookings.Fixtures
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBookings.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct. Defaults model a
  site-wide bookings admin (base + `manage_all`); pass
  `permissions: ["bookings"]` for an own-services-only user.
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, [:owner])
    permissions = Keyword.get(opts, :permissions, ["bookings", "bookings.manage_all"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: MapSet.new(roles),
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc "Plugs a fake scope into the test conn's session."
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
