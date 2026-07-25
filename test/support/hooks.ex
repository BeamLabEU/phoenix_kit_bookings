defmodule PhoenixKitBookings.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint. Replicates the
  scope assigns that core's admin/public live_sessions provide in
  production — tests set scope via `LiveCase.put_test_scope/2`.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:assign_scope, _params, session, socket) do
    case Map.get(session, "phoenix_kit_test_scope") do
      nil ->
        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end
end
