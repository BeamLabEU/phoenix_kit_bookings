defmodule PhoenixKitBookings.Web.Public.HostLive do
  @moduledoc """
  A host's public profile (`/bookings/hosts/:slug`): who they are, the
  events they run next and the services they offer. Only active profiles
  render; anything else is the not-found notice.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitBookings.Gettext

  require Logger

  alias PhoenixKitBookings.{Bookings, Events, HostProfiles, Paths, Services}
  alias PhoenixKitBookings.Web.Format
  alias PhoenixKitBookings.Web.Public.EventCard

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case PhoenixKit.Config.pubsub_server() do
        nil ->
          :ok

        pubsub ->
          Phoenix.PubSub.subscribe(pubsub, Services.services_topic())
          Phoenix.PubSub.subscribe(pubsub, Bookings.admin_topic())
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"slug" => slug}, uri, socket) do
    {:noreply, socket |> assign(url_path: URI.parse(uri).path, slug: slug) |> load()}
  end

  defp load(socket) do
    case HostProfiles.get_public_profile_by_slug(socket.assigns.slug) do
      nil ->
        assign(socket, host: nil, page_title: gettext("Not found"))

      host ->
        events = Events.list_public_upcoming(host_profile_uuid: host.uuid, limit: 50)

        socket
        |> assign(EventCard.card_assigns(events))
        |> assign(
          host: host,
          page_title: host.name,
          events: events,
          host_services: Services.with_effective_seats(HostProfiles.list_public_services(host))
        )
    end
  end

  @impl true
  def handle_info({:bookings_service_changed, _uuid}, socket), do: {:noreply, load(socket)}
  def handle_info({:bookings_changed, _uuid}, socket), do: {:noreply, load(socket)}

  def handle_info(message, socket) do
    Logger.debug("Public.HostLive ignored unhandled message: #{inspect(message)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={assigns[:url_path] || "/"}
    >
      <div class="max-w-3xl mx-auto px-4 py-10 flex flex-col gap-8">
        <div :if={is_nil(@host)} class="alert alert-warning">
          {gettext("This profile does not exist.")}
        </div>

        <%= if @host do %>
          <div class="flex flex-col sm:flex-row gap-6 items-start" id="host-profile">
            <img
              :if={@host.photo_url}
              src={@host.photo_url}
              alt={@host.name}
              class="w-32 h-32 rounded-full object-cover"
            />
            <div class="flex flex-col gap-2">
              <h1 class="text-3xl font-bold">{@host.name}</h1>
              <p :if={@host.headline} class="text-base-content/70">{@host.headline}</p>
              <p :if={@host.bio} class="whitespace-pre-line">{@host.bio}</p>
            </div>
          </div>

          <section class="flex flex-col gap-3">
            <h2 class="text-lg font-semibold">{gettext("Coming up")}</h2>
            <p :if={@events == []} class="text-base-content/60">
              {gettext("Nothing scheduled right now.")}
            </p>
            <EventCard.card
              :for={event <- @events}
              event={event}
              service={@services[event.service_uuid]}
              seats_left={@seats_left[event.uuid]}
            />
          </section>

          <section :if={@host_services != []} class="flex flex-col gap-3">
            <h2 class="text-lg font-semibold">{gettext("Services")}</h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div :for={service <- @host_services} class="card bg-base-100 shadow">
                <div class="card-body">
                  <h3 class="card-title text-base">{service.name}</h3>
                  <p :if={service.description} class="text-sm text-base-content/70">
                    {service.description}
                  </p>
                  <p class="text-xs text-base-content/50">{Format.mode_summary(service)}</p>
                  <div class="card-actions justify-end">
                    <.link navigate={Paths.public_book(service.slug)} class="btn btn-primary btn-sm">
                      {if service.bookable_online, do: gettext("Book"), else: gettext("Availability")}
                    </.link>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <.link navigate={Paths.public_schedule()} class="link">{gettext("Full schedule")}</.link>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
