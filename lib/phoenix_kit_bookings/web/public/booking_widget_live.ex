defmodule PhoenixKitBookings.Web.Public.BookingWidgetLive do
  @moduledoc """
  The embeddable booking widget — the same `BookingFlow` as the routed
  page, mountable on ANY host page via `live_render/3`:

      <%= live_render(@conn, PhoenixKitBookings.Web.Public.BookingWidgetLive,
            id: "book-massage",
            session: %{
              "slug" => "massage-60",
              "current_user_uuid" => @current_user_uuid,   # optional
              "prefill" => %{"customer_email" => @email},  # optional
              "wrapper_class" => "my-custom-frame"         # optional
            }) %>

  Deliberately exports **no `handle_params/3`** — Phoenix refuses to mount
  a LiveView that exports it outside a router live route, which would
  break embedding (the `phoenix_kit_projects` embedding lesson). Because
  `live_render` skips router `on_mount` hooks, the host passes the
  current user's uuid through the session if logged-in behavior is wanted
  (`login_required` services, prefill).
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBookings.Web.Public.BookingFlow

  @impl true
  def mount(_params, session, socket) do
    service =
      case session["slug"] do
        slug when is_binary(slug) ->
          PhoenixKitBookings.Services.get_active_service_by_slug(slug)

        _ ->
          nil
      end

    socket = assign(socket, wrapper_class: session["wrapper_class"] || "")

    case service do
      nil ->
        {:ok, assign(socket, service: nil)}

      service ->
        user = load_user(session["current_user_uuid"])
        {:ok, BookingFlow.assign_flow(socket, service, user, session["prefill"] || %{})}
    end
  end

  defp load_user(uuid) when is_binary(uuid) do
    Auth.get_user(uuid)
  rescue
    _ -> nil
  end

  defp load_user(_), do: nil

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
    <div class={@wrapper_class}>
      <div :if={is_nil(@service)} class="alert alert-warning">
        {gettext("This service is not currently taking bookings.")}
      </div>
      <BookingFlow.flow
        :if={@service}
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
    """
  end
end
