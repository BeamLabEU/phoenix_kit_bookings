defmodule PhoenixKitBookings.Web.Admin.HostsLive do
  @moduledoc """
  Admin host profiles: the public cards of the people who run services and
  events (`/bookings/hosts/:slug`). Profiles are site-wide, so the page is
  `bookings.manage_all` only; everyone else is sent back to the reservations.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitBookings.Gettext

  alias PhoenixKitBookings.{HostProfiles, Paths, Policy}
  alias PhoenixKitBookings.Schemas.HostProfile

  @impl true
  def mount(_params, _session, socket) do
    if Policy.manage_all?(scope(socket)) do
      {:ok,
       socket
       |> assign(
         page_section: gettext("Bookings"),
         page_section_path: Paths.admin_reservations(),
         page_crumbs: [],
         page_title: gettext("Hosts")
       )
       |> new_form()
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Only site-wide booking managers can edit host profiles."))
       |> push_navigate(to: Paths.admin_reservations())}
    end
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  defp load(socket), do: assign(socket, profiles: HostProfiles.list_profiles())

  defp new_form(socket),
    do: assign(socket, editing: nil, form: to_form(HostProfile.changeset(%HostProfile{}, %{})))

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, new_form(socket)}

  def handle_event("edit", %{"uuid" => uuid}, socket) do
    case HostProfiles.get_profile(uuid) do
      nil ->
        {:noreply, socket}

      profile ->
        {:noreply,
         assign(socket, editing: profile, form: to_form(HostProfile.changeset(profile, %{})))}
    end
  end

  def handle_event("validate", %{"host_profile" => params}, socket) do
    base = socket.assigns.editing || %HostProfile{}

    {:noreply,
     assign(socket, form: to_form(HostProfile.changeset(base, params), action: :validate))}
  end

  def handle_event("save", %{"host_profile" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Policy.create_host_profile(scope(socket), params)
        profile -> Policy.update_host_profile(scope(socket), profile, params)
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Host profile saved.")) |> new_form() |> load()}

      {:error, :not_allowed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Only site-wide booking managers can edit host profiles.")
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %HostProfile{} = profile <- HostProfiles.get_profile(uuid),
         {:ok, _} <- Policy.delete_host_profile(scope(socket), profile) do
      {:noreply,
       socket |> put_flash(:info, gettext("Host profile deleted.")) |> new_form() |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that profile."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6 max-w-3xl">
      <div>
        <h2 class="text-2xl font-bold">{gettext("Hosts")}</h2>
        <p class="text-sm text-base-content/60 mt-1">
          {gettext("Public profiles of the people who run your services and events. Active profiles appear on the public schedule and have a page of their own.")}
        </p>
      </div>

      <div class="card bg-base-100 shadow-lg overflow-x-auto">
        <table class="table">
          <tbody>
            <tr :for={profile <- @profiles} id={"host-#{profile.uuid}"}>
              <td class="text-sm">
                <div class="font-medium">{profile.name}</div>
                <div class="text-xs text-base-content/50">{profile.headline}</div>
              </td>
              <td>
                <span class={if profile.status == "active", do: "badge badge-success", else: "badge badge-ghost"}>
                  {if profile.status == "active", do: gettext("Active"), else: gettext("Inactive")}
                </span>
              </td>
              <td class="text-right">
                <div class="join">
                  <.link
                    :if={profile.status == "active"}
                    navigate={Paths.public_host(profile.slug)}
                    class="btn btn-xs btn-ghost join-item"
                  >
                    {gettext("View")}
                  </.link>
                  <button class="btn btn-xs join-item" phx-click="edit" phx-value-uuid={profile.uuid}>
                    {gettext("Edit")}
                  </button>
                  <button
                    class="btn btn-xs btn-ghost join-item"
                    phx-click="delete"
                    phx-value-uuid={profile.uuid}
                    data-confirm={gettext("Delete this profile? Its services and events stay.")}
                  >
                    {gettext("Delete")}
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@profiles == []}>
              <td colspan="3" class="text-center text-base-content/50 py-8">
                {gettext("No host profiles yet.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card bg-base-100 shadow-lg">
        <div class="card-body gap-3">
          <div class="flex items-center justify-between">
            <h3 class="card-title text-base">
              {if @editing, do: gettext("Edit host profile"), else: gettext("New host profile")}
            </h3>
            <button :if={@editing} class="btn btn-ghost btn-xs" phx-click="new">
              {gettext("New profile instead")}
            </button>
          </div>
          <.form
            for={@form}
            id="bookings-host-form"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-3"
          >
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input field={@form[:name]} type="text" label={gettext("Name")} />
              <.input
                field={@form[:slug]}
                type="text"
                label={gettext("Slug (public URL)")}
                placeholder={gettext("auto-generated from the name when left blank")}
              />
              <.input field={@form[:headline]} type="text" label={gettext("Headline")} />
              <.input field={@form[:photo_url]} type="url" label={gettext("Photo URL")} />
            </div>
            <.textarea field={@form[:bio]} label={gettext("About")} />
            <.select
              field={@form[:status]}
              label={gettext("Status")}
              options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
            />
            <div>
              <button type="submit" class="btn btn-primary">{gettext("Save profile")}</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
