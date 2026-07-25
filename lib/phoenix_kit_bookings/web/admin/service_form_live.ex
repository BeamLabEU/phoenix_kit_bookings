defmodule PhoenixKitBookings.Web.Admin.ServiceFormLive do
  @moduledoc """
  Create/edit form for a bookable service. The form is mode-aware: picking
  a `time_unit` (and, for minute services, toggling free-form) swaps the
  relevant rule fields in and out. Availability rules are managed inline
  on the edit page (a service must exist before rules can reference it).
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitBookings.{Paths, Policy}
  alias PhoenixKitBookings.Schemas.Service
  alias PhoenixKitBookings.Services

  @weekdays [
    {1, "Mon"},
    {2, "Tue"},
    {3, "Wed"},
    {4, "Thu"},
    {5, "Fri"},
    {6, "Sat"},
    {7, "Sun"}
  ]

  @impl true
  def mount(params, _session, socket) do
    {service, action} =
      case params["uuid"] do
        nil -> {%Service{}, :new}
        uuid -> {Services.get_service(uuid) || %Service{}, :edit}
      end

    scope = socket.assigns[:phoenix_kit_current_scope]

    blocked? =
      case action do
        :new -> not Policy.can_create?(scope)
        :edit -> is_nil(service.uuid) or not Policy.can_manage?(scope, service)
      end

    if blocked? do
      {:ok,
       socket
       |> put_flash(:error, gettext("You can't edit that service."))
       |> push_navigate(to: Paths.admin_services())}
    else
      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new, do: gettext("New Service"), else: gettext("Edit Service")),
         action: action,
         service: service,
         form: to_form(Service.changeset(service, %{}))
       )
       |> load_rules()}
    end
  end

  defp load_rules(%{assigns: %{service: %Service{uuid: nil}}} = socket),
    do: assign(socket, rules: [])

  defp load_rules(%{assigns: %{service: service}} = socket),
    do: assign(socket, rules: Services.list_rules(service.uuid))

  @impl true
  def handle_event("validate", %{"service" => params}, socket) do
    changeset = Service.changeset(socket.assigns.service, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"service" => params}, socket) do
    save(socket, socket.assigns.action, params)
  end

  def handle_event("add_rule", %{"rule" => params}, socket) do
    attrs = normalize_rule_params(params)

    case Policy.add_rule(scope(socket), socket.assigns.service, attrs) do
      {:ok, _rule} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Availability rule added.")) |> load_rules()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, rule_error(changeset))}
    end
  end

  def handle_event("delete_rule", %{"uuid" => uuid}, socket) do
    with %{} = rule <- Enum.find(socket.assigns.rules, &(&1.uuid == uuid)),
         {:ok, _} <- Policy.delete_rule(scope(socket), socket.assigns.service, rule) do
      {:noreply,
       socket |> put_flash(:info, gettext("Availability rule removed.")) |> load_rules()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that rule."))}
    end
  end

  defp save(socket, :new, params) do
    case Policy.create_service(scope(socket), params) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} created. Now add availability rules if needed.", name: service.name)
         )
         |> push_navigate(to: Paths.admin_service_edit(service.uuid))}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't create more services."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  defp save(socket, :edit, params) do
    case Policy.update_service(scope(socket), socket.assigns.service, params) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} saved.", name: service.name))
         |> assign(service: service, form: to_form(Service.changeset(service, %{})))}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that service."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :update))}
    end
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  # The add-rule mini-form posts raw params; normalize the checkbox array
  # and drop blanks so the changeset sees clean input.
  defp normalize_rule_params(params) do
    days =
      params
      |> Map.get("days_of_week", [])
      |> Enum.map(&String.to_integer/1)

    %{
      "days_of_week" => if(days == [], do: nil, else: days),
      "date" => presence(params["date"]),
      "start_time" => presence(params["start_time"]),
      "end_time" => presence(params["end_time"]),
      "available" => params["available"] != "false"
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp rule_error(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp weekdays, do: @weekdays

  defp time_unit_value(form), do: form[:time_unit].value || "minutes"
  defp flexible?(form), do: form[:flexible_duration].value in [true, "true"]
  defp minutes?(form), do: time_unit_value(form) == "minutes"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6 max-w-3xl">
      <div class="flex items-center justify-between">
        <h2 class="text-2xl font-bold">{@page_title}</h2>
        <.link navigate={Paths.admin_services()} class="btn btn-ghost btn-sm">
          {gettext("Back to services")}
        </.link>
      </div>

      <.form for={@form} phx-change="validate" phx-submit="save" class="flex flex-col gap-6">
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Basics")}</h3>
            <.input field={@form[:name]} type="text" label={gettext("Name")} />
            <.input
              field={@form[:slug]}
              type="text"
              label={gettext("Slug (public URL: /book/<slug>)")}
              placeholder={gettext("auto-generated from the name when left blank")}
            />
            <.textarea field={@form[:description]} label={gettext("Description")} />
          </div>
        </div>

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Booking shape")}</h3>

            <.select
              field={@form[:time_unit]}
              label={gettext("Time unit")}
              options={[
                {gettext("Minutes — timed bookings (slots or free-form)"), "minutes"},
                {gettext("Nights — hotel-style stays (checkout day not charged)"), "night"},
                {gettext("Days — full-day bookings"), "day"}
              ]}
            />

            <div :if={minutes?(@form)} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input
                field={@form[:duration]}
                type="number"
                label={gettext("Default length (minutes)")}
              />
              <.input
                field={@form[:slot_interval]}
                type="number"
                label={gettext("Slot start every (minutes, blank = length)")}
              />
              <div class="sm:col-span-2">
                <.checkbox
                  field={@form[:flexible_duration]}
                  label={gettext("Free-form: customers pick their own start and length")}
                />
              </div>
              <%= if flexible?(@form) do %>
                <.input
                  field={@form[:min_duration]}
                  type="number"
                  label={gettext("Minimum length (minutes, blank = default length)")}
                />
                <.input
                  field={@form[:max_duration]}
                  type="number"
                  label={gettext("Maximum length (minutes, blank = unlimited)")}
                />
              <% end %>
              <.input
                field={@form[:buffer_before]}
                type="number"
                label={gettext("Buffer before (minutes)")}
              />
              <.input
                field={@form[:buffer_after]}
                type="number"
                label={gettext("Buffer after (minutes)")}
              />
            </div>

            <div :if={!minutes?(@form)} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <.input field={@form[:min_stay]} type="number" label={gettext("Minimum stay (blank = 1)")} />
              <.input
                field={@form[:max_stay]}
                type="number"
                label={gettext("Maximum stay (blank = unlimited)")}
              />
              <.input field={@form[:checkin_time]} type="time" label={gettext("Check-in time")} />
              <.input field={@form[:checkout_time]} type="time" label={gettext("Check-out time")} />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <.input
                field={@form[:seats]}
                type="number"
                label={gettext("Capacity (rooms / seats per slot)")}
              />
              <.input
                field={@form[:min_notice]}
                type="number"
                label={gettext("Minimum notice (minutes)")}
              />
              <.input
                field={@form[:max_advance]}
                type="number"
                label={gettext("Book at most (days ahead, blank = no limit)")}
              />
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h3 class="card-title text-base">{gettext("Signup policy")}</h3>
            <.select
              field={@form[:signup_policy]}
              label={gettext("Who can book")}
              options={[
                {gettext("Anyone — guests book with name and email"), "anyone"},
                {gettext("Login required"), "login_required"}
              ]}
            />
            <.checkbox
              field={@form[:require_approval]}
              label={gettext("Require approval — new bookings wait as pending (RSVP)")}
            />
          </div>
        </div>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          <.link navigate={Paths.admin_services()} class="btn btn-ghost">{gettext("Cancel")}</.link>
        </div>
      </.form>

      <div :if={@action == :edit} class="card bg-base-100 shadow-lg">
        <div class="card-body gap-4">
          <h3 class="card-title text-base">{gettext("Availability")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("No rules = always open. Weekly rules set opening hours; a rule with a date overrides the weekly rules on that date; a closed rule blocks the day.")}
          </p>

          <table :if={@rules != []} class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Applies to")}</th>
                <th>{gettext("Hours")}</th>
                <th>{gettext("Open?")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={rule <- @rules} id={"rule-#{rule.uuid}"}>
                <td class="text-sm">{rule_scope_label(rule)}</td>
                <td class="text-sm">{rule_hours_label(rule)}</td>
                <td>
                  <span class={if rule.available, do: "badge badge-success", else: "badge badge-error"}>
                    {if rule.available, do: gettext("Open"), else: gettext("Closed")}
                  </span>
                </td>
                <td class="text-right">
                  <button
                    class="btn btn-xs btn-ghost"
                    phx-click="delete_rule"
                    phx-value-uuid={rule.uuid}
                  >
                    {gettext("Remove")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <form phx-submit="add_rule" class="flex flex-col gap-3 border-t border-base-200 pt-4">
            <div class="flex flex-wrap items-center gap-3">
              <label
                :for={{num, label} <- weekdays()}
                class="label cursor-pointer gap-1 text-sm"
              >
                <input
                  type="checkbox"
                  name="rule[days_of_week][]"
                  value={num}
                  class="checkbox checkbox-sm"
                />
                {label}
              </label>
            </div>
            <div class="flex flex-wrap items-end gap-3">
              <label class="form-control">
                <span class="label-text text-xs">{gettext("Specific date (optional)")}</span>
                <input type="date" name="rule[date]" class="input input-bordered input-sm" />
              </label>
              <label :if={minutes?(@form)} class="form-control">
                <span class="label-text text-xs">{gettext("From")}</span>
                <input type="time" name="rule[start_time]" class="input input-bordered input-sm" />
              </label>
              <label :if={minutes?(@form)} class="form-control">
                <span class="label-text text-xs">{gettext("To")}</span>
                <input type="time" name="rule[end_time]" class="input input-bordered input-sm" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">{gettext("Kind")}</span>
                <label class="select select-bordered select-sm">
                  <select name="rule[available]">
                    <option value="true">{gettext("Open")}</option>
                    <option value="false">{gettext("Closed (block out)")}</option>
                  </select>
                </label>
              </label>
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Add rule")}</button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@action == :new} class="alert">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>{gettext("Save the service first — then availability rules can be added here.")}</span>
      </div>
    </div>
    """
  end

  defp rule_scope_label(%{date: %Date{} = date}), do: Calendar.strftime(date, "%d %b %Y")

  defp rule_scope_label(%{days_of_week: days}) when is_list(days) do
    Enum.map_join(days, ", ", fn num ->
      Enum.find_value(@weekdays, fn {n, label} -> n == num && label end)
    end)
  end

  defp rule_scope_label(_), do: "—"

  defp rule_hours_label(%{start_time: %Time{} = s, end_time: %Time{} = e}),
    do: "#{Calendar.strftime(s, "%H:%M")}–#{Calendar.strftime(e, "%H:%M")}"

  defp rule_hours_label(_), do: gettext("whole day")
end
