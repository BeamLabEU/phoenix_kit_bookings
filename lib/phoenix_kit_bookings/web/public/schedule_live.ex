defmodule PhoenixKitBookings.Web.Public.ScheduleLive do
  @moduledoc """
  The public schedule (`/bookings/schedule`): what's on — upcoming public
  events, grouped by day in the site frame, each with who runs it and the
  seats left — and the hosts who run them. Live: event and booking changes
  re-render it.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitBookings.Gettext

  require Logger

  alias PhoenixKitBookings.{Bookings, Engine, Events, HostProfiles, Paths, Services}
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

    {:ok, socket |> assign(page_title: gettext("What's on")) |> load()}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, url_path: URI.parse(uri).path)}
  end

  defp load(socket) do
    events = Events.list_public_upcoming()

    assign(
      socket,
      EventCard.card_assigns(events) ++
        [days: group_by_day(events), hosts: HostProfiles.list_public_profiles()]
    )
  end

  defp group_by_day(events) do
    tz = Engine.site_tz()

    events
    |> Enum.group_by(&(&1.starts_at |> Engine.to_frame(tz) |> DateTime.to_date()))
    |> Enum.sort_by(fn {date, _} -> date end, Date)
  end

  @impl true
  def handle_info({:bookings_service_changed, _uuid}, socket), do: {:noreply, load(socket)}
  def handle_info({:bookings_changed, _uuid}, socket), do: {:noreply, load(socket)}

  def handle_info(message, socket) do
    Logger.debug("Public.ScheduleLive ignored unhandled message: #{inspect(message)}")
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
        <h1 class="text-3xl font-bold">{gettext("What's on")}</h1>

        <div :if={@days == []} class="text-base-content/60" id="schedule-empty">
          {gettext("Nothing is scheduled right now.")}
        </div>

        <section :for={{date, events} <- @days} class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{EventCard.day_label(date)}</h2>
          <EventCard.card
            :for={event <- events}
            event={event}
            service={@services[event.service_uuid]}
            host={@hosts_by_uuid[EventCard.host_uuid(event, @services)]}
            seats_left={@seats_left[event.uuid]}
          />
        </section>

        <section :if={@hosts != []} class="flex flex-col gap-3" id="schedule-hosts">
          <h2 class="text-lg font-semibold">{gettext("Who runs it")}</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.link
              :for={host <- @hosts}
              navigate={Paths.public_host(host.slug)}
              class="card bg-base-100 shadow hover:shadow-lg"
            >
              <div class="card-body flex-row items-center gap-4">
                <img
                  :if={host.photo_url}
                  src={host.photo_url}
                  alt={host.name}
                  class="w-14 h-14 rounded-full object-cover"
                />
                <div>
                  <div class="font-semibold">{host.name}</div>
                  <div :if={host.headline} class="text-sm text-base-content/60">{host.headline}</div>
                </div>
              </div>
            </.link>
          </div>
        </section>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
