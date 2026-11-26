defmodule PhoenixKitBookings.Web.Admin.EventsLive do
  @moduledoc """
  Admin events: the dated occurrences (classes, tours) the public schedule
  lists. One page — the upcoming / all list with seats taken, and an inline
  form to add or edit an event of a service the viewer manages. Times are
  entered and shown in the site frame. Every read and mutation goes through
  `Policy`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitBookings.Gettext

  require Logger

  alias PhoenixKitBookings.{Bookings, Engine, Events, HostProfiles, Paths, Policy}
  alias PhoenixKitBookings.Schemas.Event
  alias PhoenixKitBookings.Web.Format
  alias PhoenixKitBookings.Web.Public.EventCard

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case PhoenixKit.Config.pubsub_server() do
        nil -> :ok
        pubsub -> Phoenix.PubSub.subscribe(pubsub, Bookings.admin_topic())
      end
    end

    {:ok,
     socket
     |> assign(
       page_section: gettext("Bookings"),
       page_section_path: Paths.admin_reservations(),
       page_crumbs: [],
       page_title: gettext("Events"),
       filter: "upcoming",
       editing: nil
     )
     |> new_form()
     |> load()}
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  defp load(socket) do
    scope = scope(socket)
    services = Policy.visible_services(scope)
    opts = if socket.assigns.filter == "upcoming", do: [upcoming: true], else: []
    events = Policy.visible_events(scope, opts)

    assign(socket,
      events: events,
      services: Map.new(Policy.visible_services(scope, include_trashed: true), &{&1.uuid, &1}),
      service_options: Enum.map(services, &{&1.name, &1.uuid}),
      host_options: Enum.map(HostProfiles.list_profiles(), &{&1.name, &1.uuid}),
      taken: Bookings.event_seats_taken_map(Enum.map(events, & &1.uuid))
    )
  end

  defp new_form(socket) do
    assign(socket, editing: nil, form: to_form(%{}, as: :event), form_errors: [])
  end

  defp edit_form(socket, %Event{} = event) do
    params = %{
      "service_uuid" => event.service_uuid,
      "host_profile_uuid" => event.host_profile_uuid,
      "title" => event.title,
      "description" => event.description,
      "location" => event.location,
      "starts_local" => to_local_input(event.starts_at),
      "ends_local" => to_local_input(event.ends_at),
      "capacity" => event.capacity,
      "price" => event.price && Decimal.to_string(event.price),
      "public" => event.public,
      "ignore_service_capacity" => Event.ignore_service_capacity?(event)
    }

    assign(socket, editing: event, form: to_form(params, as: :event), form_errors: [])
  end

  defp to_local_input(%DateTime{} = dt),
    do: dt |> Engine.utc_to_frame() |> Calendar.strftime("%Y-%m-%dT%H:%M")

  # The form's site-frame wall clocks, as the UTC instants an event stores.
  defp to_attrs(params) do
    %{
      "service_uuid" => blank(params["service_uuid"]),
      "host_profile_uuid" => blank(params["host_profile_uuid"]),
      "title" => params["title"],
      "description" => blank(params["description"]),
      "location" => blank(params["location"]),
      "starts_at" => from_local_input(params["starts_local"]),
      "ends_at" => from_local_input(params["ends_local"]),
      "capacity" => blank(params["capacity"]),
      "price" => blank(params["price"]),
      "public" => params["public"] in ["true", "on", true],
      "ignore_service_capacity" => params["ignore_service_capacity"] in ["true", "on", true]
    }
  end

  defp from_local_input(value) when is_binary(value) and value != "" do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} ->
        Engine.frame_to_utc(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive))

      _ ->
        nil
    end
  end

  defp from_local_input(_), do: nil

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) when filter in ["upcoming", "all"] do
    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  def handle_event("new", _params, socket), do: {:noreply, new_form(socket)}

  def handle_event("edit", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.events, &(&1.uuid == uuid)) do
      nil -> {:noreply, socket}
      event -> {:noreply, edit_form(socket, event)}
    end
  end

  def handle_event("save", %{"event" => params}, socket) do
    attrs = to_attrs(params)

    result =
      case socket.assigns.editing do
        nil -> Policy.create_event(scope(socket), attrs)
        %Event{} = event -> Policy.update_event(scope(socket), event, attrs)
      end

    case result do
      {:ok, _event} ->
        {:noreply, socket |> put_flash(:info, gettext("Event saved.")) |> new_form() |> load()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't manage events of that service."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :event),
           form_errors:
             Enum.map(changeset.errors, fn {field, {msg, opts}} ->
               "#{field}: #{interpolate(msg, opts)}"
             end)
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("This event does not exist or is no longer on the schedule.")
         )
         |> new_form()
         |> load()}
    end
  end

  def handle_event("cancel_event", %{"uuid" => uuid}, socket) do
    with %Event{} = event <- Events.get_event(uuid),
         {:ok, _} <- Policy.cancel_event(scope(socket), event) do
      {:noreply, socket |> put_flash(:info, gettext("Event cancelled.")) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not cancel that event."))}
    end
  end

  def handle_event("delete_event", %{"uuid" => uuid}, socket) do
    with %Event{} = event <- Events.get_event(uuid),
         {:ok, _} <- Policy.delete_event(scope(socket), event) do
      {:noreply, socket |> put_flash(:info, gettext("Event deleted.")) |> new_form() |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that event."))}
    end
  end

  @impl true
  def handle_info({:bookings_changed, _uuid}, socket), do: {:noreply, load(socket)}

  def handle_info(message, socket) do
    Logger.debug("EventsLive ignored unhandled message: #{inspect(message)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 class="text-2xl font-bold">{gettext("Events")}</h2>
          <p class="text-sm text-base-content/60 mt-1">
            {gettext("Dated occurrences with their own capacity — what the public schedule lists.")}
          </p>
        </div>
        <.link navigate={Paths.public_schedule()} class="btn btn-ghost btn-sm">
          {gettext("Public schedule")}
        </.link>
      </div>

      <div class="join w-fit">
        <button
          :for={{id, label} <- [{"upcoming", gettext("Upcoming")}, {"all", gettext("All")}]}
          class={["btn btn-sm join-item", @filter == id && "btn-active"]}
          phx-click="filter"
          phx-value-filter={id}
        >
          {label}
        </button>
      </div>

      <div class="card bg-base-100 shadow-lg overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("When")}</th>
              <th>{gettext("Event")}</th>
              <th>{gettext("Places")}</th>
              <th>{gettext("Status")}</th>
              <th class="text-right">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @events} id={"admin-event-#{event.uuid}"}>
              <td class="text-sm whitespace-nowrap">
                {Format.format_instant(event.starts_at)}
                <div class="text-xs text-base-content/50">{EventCard.time_range(event)}</div>
              </td>
              <td class="text-sm">
                <div class="font-medium">{event.title}</div>
                <div class="text-xs text-base-content/50">
                  {(@services[event.service_uuid] && @services[event.service_uuid].name) || "—"}
                  <span :if={!event.public}>· {gettext("not public")}</span>
                </div>
              </td>
              <td class="text-sm">
                {Map.get(@taken, event.uuid, 0)} / {event.capacity || gettext("service capacity")}
              </td>
              <td>
                <span class={if event.status == "scheduled", do: "badge badge-success", else: "badge badge-ghost"}>
                  {if event.status == "scheduled", do: gettext("scheduled"), else: gettext("cancelled")}
                </span>
              </td>
              <td class="text-right">
                <div class="join">
                  <button class="btn btn-xs join-item" phx-click="edit" phx-value-uuid={event.uuid}>
                    {gettext("Edit")}
                  </button>
                  <button
                    :if={event.status == "scheduled"}
                    class="btn btn-xs btn-ghost join-item"
                    phx-click="cancel_event"
                    phx-value-uuid={event.uuid}
                    data-confirm={gettext("Cancel this event? Everyone signed up is told.")}
                  >
                    {gettext("Cancel")}
                  </button>
                  <button
                    class="btn btn-xs btn-ghost join-item"
                    phx-click="delete_event"
                    phx-value-uuid={event.uuid}
                    data-confirm={gettext("Delete this event? Its bookings stay in the reservations list.")}
                  >
                    {gettext("Delete")}
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@events == []}>
              <td colspan="5" class="text-center text-base-content/50 py-8">
                {gettext("No events yet.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card bg-base-100 shadow-lg">
        <div class="card-body gap-4">
          <div class="flex items-center justify-between">
            <h3 class="card-title text-base">
              {if @editing, do: gettext("Edit event"), else: gettext("New event")}
            </h3>
            <button :if={@editing} class="btn btn-ghost btn-xs" phx-click="new">
              {gettext("New event instead")}
            </button>
          </div>

          <p :if={@service_options == []} class="text-sm text-base-content/60">
            {gettext("Create a service first: every event is an occurrence of one.")}
          </p>

          <div :if={@form_errors != []} class="alert alert-error text-sm">
            <ul>
              <li :for={error <- @form_errors}>{error}</li>
            </ul>
          </div>

          <.form
            :if={@service_options != []}
            for={@form}
            id="bookings-event-form"
            phx-submit="save"
            class="flex flex-col gap-3"
          >
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.select
                field={@form[:service_uuid]}
                label={gettext("Service")}
                options={@service_options}
              />
              <.select
                field={@form[:host_profile_uuid]}
                label={gettext("Run by")}
                prompt={gettext("The service's host")}
                options={@host_options}
              />
              <.input field={@form[:title]} type="text" label={gettext("Title")} required />
              <.input field={@form[:location]} type="text" label={gettext("Location (optional)")} />
              <.input field={@form[:starts_local]} type="datetime-local" label={gettext("Starts")} required />
              <.input field={@form[:ends_local]} type="datetime-local" label={gettext("Ends")} required />
              <.input
                field={@form[:capacity]}
                type="number"
                label={gettext("Places (blank = the service's capacity)")}
              />
              <.input
                field={@form[:price]}
                type="number"
                step="0.01"
                label={gettext("Price (blank = the service's price)")}
              />
            </div>
            <.textarea field={@form[:description]} label={gettext("Description")} />
            <input type="hidden" name="event[public]" value="false" />
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="event[public]"
                value="true"
                class="checkbox checkbox-sm"
                checked={@form[:public].value in [nil, true, "true"]}
              />
              <span>{gettext("Show on the public schedule")}</span>
            </label>
            <input type="hidden" name="event[ignore_service_capacity]" value="false" />
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="event[ignore_service_capacity]"
                value="true"
                class="checkbox checkbox-sm"
                checked={@form[:ignore_service_capacity].value in [true, "true"]}
              />
              <span>
                {gettext("Sell its seats even when the service's own bookings fill it at that time")}
              </span>
            </label>
            <div>
              <button type="submit" class="btn btn-primary">{gettext("Save event")}</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp interpolate(msg, opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
