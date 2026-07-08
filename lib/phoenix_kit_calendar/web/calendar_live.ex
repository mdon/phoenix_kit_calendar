defmodule PhoenixKitCalendar.Web.CalendarLive do
  @moduledoc """
  The calendar admin page — your own month calendar, and (for holders of
  `calendar.view_others`) anyone else's via the person switcher.

  ## Authorization

  Page access is gated by the base `calendar` permission (PhoenixKit's
  admin on_mount chain). Everything finer-grained goes through
  `PhoenixKitCalendar.Events`, which re-checks the caller's scope against
  the viewed calendar's owner on every read and write — the UI merely
  mirrors those rules (`can_edit_viewed?` hides buttons; the context
  enforces).

  The `?user=<uuid>` query param selects another user's calendar. An
  unauthorized or unknown `user` param silently falls back to the
  viewer's own calendar.

  ## Time semantics (v1)

  Timed events are entered and displayed as naive wall-clock times
  (stored as UTC instants verbatim — no timezone conversion). All-day
  events use real dates. The end-date field on all-day events is
  INCLUSIVE in the form ("last day") and converted to the exclusive
  storage form on save.
  """
  use PhoenixKitWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixLiveCalendar.Utils.DateHelpers

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    own_uuid = scope && Scope.user_uuid(scope)
    today = Date.utc_today()
    {from, until} = DateHelpers.visible_range(:month, today)

    can_view_others? =
      Scope.can?(scope, "calendar.view_others") or Scope.can?(scope, "calendar.edit_others")

    socket =
      socket
      |> assign(:page_title, Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar"))
      |> assign(:scope, scope)
      |> assign(:own_uuid, own_uuid)
      |> assign(:today, today)
      |> assign(:window, {from, until})
      |> assign(:can_view_others?, can_view_others?)
      |> assign(:switcher_users, if(can_view_others?, do: load_switcher_users(scope), else: []))
      |> assign(:show_event_modal, false)
      |> assign(:editing_event, nil)
      |> assign(:event_form, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    scope = socket.assigns.scope
    own_uuid = socket.assigns.own_uuid

    viewing_uuid =
      case params["user"] do
        uuid when is_binary(uuid) and uuid != own_uuid ->
          if Events.can_view?(scope, uuid) and known_user?(socket, uuid),
            do: uuid,
            else: own_uuid

        _ ->
          own_uuid
      end

    socket =
      socket
      |> assign(:viewing_uuid, viewing_uuid)
      |> assign(:own_calendar?, viewing_uuid == own_uuid)
      |> assign(:can_edit_viewed?, Events.can_edit?(scope, viewing_uuid))
      |> assign(:viewing_label, user_label(socket, viewing_uuid))
      |> reload_events()

    {:noreply, socket}
  end

  # ── Calendar component callbacks (arrive as messages) ─────────────────────

  @impl true
  def handle_info({:calendar_range_change, %{start: from, end: until}}, socket) do
    socket =
      socket
      |> assign(:window, {from, until})
      |> reload_events()

    {:noreply, socket}
  end

  def handle_info({:calendar_date_click, %Date{} = date}, socket) do
    if socket.assigns.can_edit_viewed? do
      changeset =
        Event.changeset(%Event{}, %{
          "all_day" => "false",
          "starts_at" => DateTime.new!(date, ~T[09:00:00], "Etc/UTC"),
          "ends_at" => DateTime.new!(date, ~T[10:00:00], "Etc/UTC")
        })

      {:noreply, open_modal(socket, nil, changeset)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:calendar_event_click, event_id}, socket) do
    case Events.get_event(socket.assigns.scope, event_id) do
      {:ok, event} ->
        {:noreply, open_modal(socket, event, Event.changeset(event, %{}))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Event not found")
         )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_user", %{"user" => uuid}, socket) do
    own_uuid = socket.assigns.own_uuid

    to =
      if uuid == own_uuid or uuid == "" do
        PhoenixKitCalendar.Paths.index()
      else
        PhoenixKitCalendar.Paths.for_user(uuid)
      end

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("new_event", _params, socket) do
    if socket.assigns.can_edit_viewed? do
      send(self(), {:calendar_date_click, socket.assigns.today})
    end

    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("validate_event", %{"event" => params}, socket) do
    changeset =
      (socket.assigns.editing_event || %Event{})
      |> Event.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :event_form, to_form(changeset, as: "event"))}
  end

  def handle_event("save_event", %{"event" => params}, socket) do
    %{scope: scope, viewing_uuid: viewing_uuid, editing_event: editing} = socket.assigns
    params = normalize_params(params)

    result =
      case editing do
        nil -> Events.create_event(scope, viewing_uuid, params)
        %Event{} = event -> Events.update_event(scope, event, params)
      end

    case result do
      {:ok, _event} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Event saved"))
         |> close_modal()
         |> reload_events()}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "You are not allowed to edit this calendar")
         )
         |> close_modal()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :event_form, to_form(changeset, as: "event"))}
    end
  end

  def handle_event("delete_event", _params, socket) do
    case socket.assigns.editing_event do
      %Event{} = event ->
        case Events.delete_event(socket.assigns.scope, event) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Event deleted"))
             |> close_modal()
             |> reload_events()}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               Gettext.gettext(PhoenixKitWeb.Gettext, "Could not delete this event")
             )}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # ── Data loading ───────────────────────────────────────────────────────────

  defp reload_events(socket) do
    %{scope: scope, viewing_uuid: viewing_uuid, window: {from, until}} = socket.assigns

    events =
      case Events.list_events(scope, viewing_uuid, from, until) do
        {:ok, events} -> Enum.map(events, &to_lib_event/1)
        {:error, :unauthorized} -> []
      end

    assign(socket, :calendar_events, events)
  end

  defp to_lib_event(%Event{all_day: true} = event) do
    %PhoenixLiveCalendar.Event{
      id: event.uuid,
      title: event.title,
      start: event.starts_on,
      end: event.ends_on,
      all_day: true,
      color: event.color,
      description: event.description,
      location: event.location,
      status: status_atom(event.status)
    }
  end

  defp to_lib_event(%Event{} = event) do
    %PhoenixLiveCalendar.Event{
      id: event.uuid,
      title: event.title,
      start: event.starts_at,
      end: event.ends_at,
      color: event.color,
      description: event.description,
      location: event.location,
      status: status_atom(event.status)
    }
  end

  defp status_atom("cancelled"), do: :cancelled
  defp status_atom(_), do: :confirmed

  # All active users for the person switcher, annotated with whether they
  # currently hold calendar access (through any role) and how many events
  # they have. Deliberately lists users WITHOUT access too — an admin may
  # need to review the calendar of someone whose permissions were revoked.
  defp load_switcher_users(scope) do
    access_set = calendar_access_set()

    counts =
      case Events.count_events_by_owner(scope) do
        {:ok, counts} -> counts
        {:error, _} -> %{}
      end

    from(u in PhoenixKit.Users.Auth.User,
      where: u.is_active == true,
      order_by: [asc: u.email],
      select: %{uuid: u.uuid, email: u.email, first_name: u.first_name, last_name: u.last_name}
    )
    |> RepoHelper.repo().all()
    |> Enum.map(fn u ->
      %{
        uuid: u.uuid,
        label: display_name(u),
        has_access?: MapSet.member?(access_set, u.uuid),
        has_events?: Map.get(counts, u.uuid, 0) > 0
      }
    end)
  end

  # Users holding the calendar permission through any role, plus Owners
  # (whose access is implicit — they have no permission rows).
  defp calendar_access_set do
    with_permission = Permissions.users_with_permission("calendar")

    owners =
      "Owner"
      |> Roles.users_with_role()
      |> Enum.map(& &1.uuid)

    MapSet.new(with_permission ++ owners)
  rescue
    _ -> MapSet.new()
  end

  defp display_name(%{first_name: first, last_name: last, email: email}) do
    case String.trim("#{first || ""} #{last || ""}") do
      "" -> email
      name -> name
    end
  end

  defp known_user?(socket, uuid) do
    Enum.any?(socket.assigns.switcher_users, &(&1.uuid == uuid))
  end

  defp user_label(socket, uuid) do
    case Enum.find(socket.assigns.switcher_users, &(&1.uuid == uuid)) do
      nil -> nil
      user -> user.label
    end
  end

  # ── Modal helpers ──────────────────────────────────────────────────────────

  defp open_modal(socket, event, changeset) do
    socket
    |> assign(:editing_event, event)
    |> assign(:event_form, to_form(inclusive_end(changeset), as: "event"))
    |> assign(:show_event_modal, true)
  end

  defp close_modal(socket) do
    socket
    |> assign(:show_event_modal, false)
    |> assign(:editing_event, nil)
    |> assign(:event_form, nil)
  end

  # The form shows the all-day end date INCLUSIVE ("last day"); storage is
  # exclusive. Shift on the way in (here) and on the way out
  # (normalize_params/1).
  defp inclusive_end(changeset) do
    case Ecto.Changeset.get_field(changeset, :ends_on) do
      %Date{} = ends_on ->
        Ecto.Changeset.put_change(changeset, :ends_on, Date.add(ends_on, -1))

      _ ->
        changeset
    end
  end

  defp normalize_params(%{"all_day" => all_day} = params)
       when all_day in [true, "true", "on"] do
    case Date.from_iso8601(params["ends_on"] || "") do
      {:ok, last_day} -> Map.put(params, "ends_on", Date.to_iso8601(Date.add(last_day, 1)))
      _ -> params
    end
  end

  defp normalize_params(params), do: params

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-4">
      <%!-- Toolbar: whose calendar + actions --%>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <h1 class="text-2xl font-bold">
            <.icon name="hero-calendar-days" class="w-7 h-7 inline-block mr-1" />
            <%= if @own_calendar? do %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "My calendar")}
            <% else %>
              {@viewing_label || Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar")}
            <% end %>
          </h1>
          <span
            :if={not @own_calendar? and not @can_edit_viewed?}
            class="badge badge-warning gap-1"
          >
            <.icon name="hero-eye" class="w-3.5 h-3.5" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Read only")}
          </span>
        </div>

        <div class="flex items-center gap-2">
          <%!-- Person switcher — only for calendar.view_others holders --%>
          <form :if={@can_view_others?} id="calendar-user-switcher" phx-change="switch_user">
            <label class="select select-sm">
              <span class="label">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar of")}
              </span>
              <select name="user">
                <option value="" selected={@own_calendar?}>
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Me")}
                </option>
                <option
                  :for={user <- @switcher_users}
                  :if={user.uuid != @own_uuid}
                  value={user.uuid}
                  selected={user.uuid == @viewing_uuid}
                >
                  {user.label}{switcher_annotation(user)}
                </option>
              </select>
            </label>
          </form>

          <button
            :if={@can_edit_viewed?}
            phx-click="new_event"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New event")}
          </button>
        </div>
      </div>

      <%!-- The month calendar (server-rendered) --%>
      <div class="card bg-base-100 shadow">
        <div class="card-body p-3 sm:p-5">
          <.live_component
            module={PhoenixLiveCalendar.CalendarComponent}
            id="pk-calendar"
            events={@calendar_events}
            views={[:month]}
            date={@today}
            today={@today}
            on_date_select={fn date -> send(self(), {:calendar_date_click, date}) end}
            on_event_click={fn id -> send(self(), {:calendar_event_click, id}) end}
            on_date_range_change={fn range -> send(self(), {:calendar_range_change, range}) end}
          />
        </div>
      </div>

      <%!-- Event create/edit/details modal --%>
      <.modal :if={@show_event_modal} show={@show_event_modal} on_close="close_modal" max_width="2xl">
        <:title>
          <%= cond do %>
            <% is_nil(@editing_event) -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "New event")}
            <% @can_edit_viewed? -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit event")}
            <% true -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Event")}
          <% end %>
        </:title>

        <%= if @can_edit_viewed? do %>
          <.form
            for={@event_form}
            id="calendar-event-form"
            phx-change="validate_event"
            phx-submit="save_event"
            class="space-y-3"
          >
            <.input
              field={@event_form[:title]}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Title")}
              required
            />
            <.checkbox
              field={@event_form[:all_day]}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "All day")}
            />

            <%= if Phoenix.HTML.Form.normalize_value("checkbox", @event_form[:all_day].value) do %>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input
                  field={@event_form[:starts_on]}
                  type="date"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Start date")}
                />
                <.input
                  field={@event_form[:ends_on]}
                  type="date"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "End date (last day)")}
                />
              </div>
            <% else %>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input
                  field={@event_form[:starts_at]}
                  type="datetime-local"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Starts")}
                />
                <.input
                  field={@event_form[:ends_at]}
                  type="datetime-local"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Ends")}
                />
              </div>
            <% end %>

            <.input
              field={@event_form[:location]}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Location")}
            />
            <.textarea
              field={@event_form[:description]}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
            />

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.select
                field={@event_form[:color]}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Color")}
                options={color_options()}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "Default")}
              />
              <.select
                field={@event_form[:status]}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}
                options={status_options()}
              />
            </div>
          </.form>
        <% else %>
          <%!-- Read-only details for view_others-without-edit --%>
          <div :if={@editing_event} class="space-y-2">
            <p class="text-lg font-semibold">{@editing_event.title}</p>
            <p class="text-sm text-base-content/70">{event_when(@editing_event)}</p>
            <p :if={@editing_event.location} class="text-sm">
              <.icon name="hero-map-pin" class="w-4 h-4 inline-block" /> {@editing_event.location}
            </p>
            <p :if={@editing_event.description} class="text-sm whitespace-pre-wrap">
              {@editing_event.description}
            </p>
            <span :if={@editing_event.status == "cancelled"} class="badge badge-error badge-outline">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancelled")}
            </span>
          </div>
        <% end %>

        <:actions>
          <button
            :if={@can_edit_viewed? and not is_nil(@editing_event)}
            type="button"
            phx-click="delete_event"
            data-confirm={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete this event?")}
            class="btn btn-error btn-outline mr-auto"
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
          </button>
          <button type="button" phx-click="close_modal" class="btn btn-outline">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Close")}
          </button>
          <button
            :if={@can_edit_viewed?}
            type="submit"
            form="calendar-event-form"
            class="btn btn-primary"
            phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Save")}
          </button>
        </:actions>
      </.modal>
    </div>
    """
  end

  defp switcher_annotation(user) do
    cond do
      not user.has_access? and user.has_events? ->
        " " <> Gettext.gettext(PhoenixKitWeb.Gettext, "(no calendar access, has events)")

      not user.has_access? ->
        " " <> Gettext.gettext(PhoenixKitWeb.Gettext, "(no calendar access)")

      not user.has_events? ->
        " " <> Gettext.gettext(PhoenixKitWeb.Gettext, "(empty)")

      true ->
        ""
    end
  end

  defp event_when(%Event{all_day: true} = event) do
    last_day = Date.add(event.ends_on, -1)

    if Date.compare(event.starts_on, last_day) == :eq do
      "#{event.starts_on}"
    else
      "#{event.starts_on} – #{last_day}"
    end
  end

  defp event_when(%Event{} = event) do
    "#{Calendar.strftime(event.starts_at, "%Y-%m-%d %H:%M")} – #{Calendar.strftime(event.ends_at, "%H:%M")}"
  end

  defp color_options do
    [
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Blue"), "bg-primary"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Purple"), "bg-secondary"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Teal"), "bg-accent"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Info"), "bg-info"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Green"), "bg-success"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Yellow"), "bg-warning"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Red"), "bg-error"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Gray"), "bg-neutral"}
    ]
  end

  defp status_options do
    [
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Confirmed"), "confirmed"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancelled"), "cancelled"}
    ]
  end
end
