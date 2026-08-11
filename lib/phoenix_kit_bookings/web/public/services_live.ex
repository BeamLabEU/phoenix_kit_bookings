defmodule PhoenixKitBookings.Web.Public.ServicesLive do
  @moduledoc """
  Public index of active bookable services (`/bookings`) — name,
  description, shape summary, and a Book link per service. Live: service
  config changes re-render the list.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitBookings.{Paths, Services}
  alias PhoenixKitBookings.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case PhoenixKit.Config.pubsub_server() do
        nil -> :ok
        pubsub -> Phoenix.PubSub.subscribe(pubsub, Services.services_topic())
      end
    end

    {:ok,
     assign(socket,
       page_title: gettext("Book with us"),
       services: Services.list_public_services()
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, url_path: URI.parse(uri).path)}
  end

  @impl true
  def handle_info({:bookings_service_changed, _uuid}, socket) do
    {:noreply, assign(socket, services: Services.list_public_services())}
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
      <div class="max-w-3xl mx-auto px-4 py-10 flex flex-col gap-6">
        <h1 class="text-3xl font-bold">{gettext("Book with us")}</h1>

        <div :if={@services == []} class="text-base-content/60">
          {gettext("Nothing is open for booking right now.")}
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div :for={service <- @services} class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title">{service.name}</h2>
              <p :if={service.description} class="text-sm text-base-content/70">
                {service.description}
              </p>
              <p class="text-xs text-base-content/50">{Format.mode_summary(service)}</p>
              <div class="card-actions justify-end mt-2">
                <.link navigate={Paths.public_book(service.slug)} class="btn btn-primary btn-sm">
                  {gettext("Book")}
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
