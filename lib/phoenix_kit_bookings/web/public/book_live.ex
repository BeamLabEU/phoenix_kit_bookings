defmodule PhoenixKitBookings.Web.Public.BookLive do
  @moduledoc """
  The routed public booking page (`/book/:slug`) — a thin shell around
  `BookingFlow`, wrapped in the host layout via `LayoutWrapper.app_layout`.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitBookings.Web.Public.BookingFlow

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"slug" => slug} = _params, uri, socket) do
    socket = assign(socket, url_path: URI.parse(uri).path)

    case PhoenixKitBookings.Services.get_active_service_by_slug(slug) do
      nil ->
        {:noreply, assign(socket, service: nil, page_title: gettext("Not found"))}

      service ->
        {:noreply,
         socket
         |> assign(page_title: service.name)
         |> BookingFlow.assign_flow(service, current_user(socket))}
    end
  end

  defp current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> user
      _ -> nil
    end
  end

  @impl true
  def handle_event(event, params, socket), do: BookingFlow.handle_event(event, params, socket)

  @impl true
  def handle_info(message, socket), do: BookingFlow.handle_info(message, socket)

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:service], do: BookingFlow.on_terminate(socket)
    :ok
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
      <div class="max-w-2xl mx-auto px-4 py-10">
        <div :if={is_nil(@service)} class="alert alert-warning">
          {gettext("This booking page does not exist or is no longer taking bookings.")}
        </div>
        <div :if={@service} class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <BookingFlow.flow
              service={@service}
              rules={@rules}
              step={@step}
              pick_date={@pick_date}
              slots={@slots}
              day_capacity={@day_capacity}
              selected_range={@selected_range}
              customer_form={@customer_form}
              booking={@booking}
              flow_error={@flow_error}
              flow_error_reason={@flow_error_reason}
              waitlist_done={@waitlist_done}
              current_user={@current_user}
            />
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
