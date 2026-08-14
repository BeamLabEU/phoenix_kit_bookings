defmodule PhoenixKitBookings.Web.Admin.SettingsLive do
  @moduledoc """
  Module settings: the self-service policy. Only `bookings.manage_all`
  holders may view or save (the settings decide what everyone ELSE may
  do, so base-permission holders have no business here).
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBookings.Policy

  @impl true
  def mount(_params, _session, socket) do
    if Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope]) do
      {:ok,
       assign(socket,
         page_title: gettext("Bookings Settings"),
         user_services_enabled: Policy.user_services_enabled?(),
         max_services: Policy.max_services_per_user()
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have access to the Bookings settings."))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    if Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope]) do
      enabled = params["user_services_enabled"] == "true"
      max = parse_max(params["max_services_per_user"])

      Settings.update_boolean_setting_with_module(
        "bookings_user_services_enabled",
        enabled,
        "bookings"
      )

      Settings.update_setting_with_module(
        "bookings_max_services_per_user",
        Integer.to_string(max),
        "bookings"
      )

      {:noreply,
       socket
       |> put_flash(:info, gettext("Settings saved."))
       |> assign(user_services_enabled: enabled, max_services: max)}
    else
      {:noreply, socket}
    end
  end

  defp parse_max(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n >= 0 -> n
      _ -> 1
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6 max-w-2xl">
      <div>
        <h2 class="text-2xl font-bold">{gettext("Bookings Settings")}</h2>
        <p class="text-sm text-base-content/60 mt-1">
          {gettext("Control whether users with the base Bookings permission can set up their own bookable services.")}
        </p>
      </div>

      <form phx-submit="save" class="card bg-base-100 shadow-lg">
        <div class="card-body gap-4">
          <label class="label cursor-pointer justify-start gap-3">
            <input type="hidden" name="settings[user_services_enabled]" value="false" />
            <input
              type="checkbox"
              name="settings[user_services_enabled]"
              value="true"
              checked={@user_services_enabled}
              class="toggle"
            />
            <span class="fieldset-legend">
              {gettext("Users may create their own services")}
            </span>
          </label>

          <label class="fieldset max-w-xs">
            <span class="fieldset-legend text-sm">
              {gettext("Services per user (0 = unlimited)")}
            </span>
            <input
              type="number"
              name="settings[max_services_per_user]"
              value={@max_services}
              min="0"
              class="input"
            />
          </label>

          <p class="text-xs text-base-content/50">
            {gettext("Users manage only the services they own. Granting \"Manage all bookings\" lifts a user to site-wide management.")}
          </p>

          <div>
            <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          </div>
        </div>
      </form>
    </div>
    """
  end
end
