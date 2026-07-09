defmodule PhoenixKitCalendar.Web.CalendarLive do
  @moduledoc """
  The calendar admin page.

  ## Interaction model (quorum-designed, 2026-07-09)

  What you see is a SET of calendar layers. "Me" is the default set
  `{me}`; viewing one person is a set of size 1; "Everyone" is a
  select-all-permitted shortcut, not a mode. Holders of
  `calendar.view_others` get a toolbar "Calendars · N" button opening a
  Google-Calendar-style checklist panel: search, Me/Everyone shortcuts,
  and a checkbox list where every person carries a deterministic palette
  color — events on the grid are tinted with their owner's color instead
  of name prefixes. Clicking a NAME solos that person; the checkbox
  toggles membership. People without calendar access stay selectable
  (their history must remain reviewable) and are badged; people with no
  events in the visible range get an "empty" badge.

  ## State

  The selection lives in the URL (`?people=uuid1,uuid2` or
  `?people=all`; absent = own calendar), so views are shareable and the
  back button works. Every mount/patch SANITIZES the list — unknown ids
  are dropped, and viewers without `calendar.view_others` are forced to
  `{me}` regardless of the URL (authorization is enforced on the query
  in `PhoenixKitCalendar.Events`, not just in the template).

  ## Authorization

  Page access needs the base `calendar` key (admin on_mount chain).
  Everything finer goes through the Events context, which re-checks the
  caller's scope against each event's persisted owner. The modal
  authorizes PER EVENT at open time (`can_edit_event?`), so with
  `calendar.edit_others` you edit anyone's event inline from any view;
  without it you get read-only details. Creating needs exactly one
  selected calendar you may edit.

  ## Time semantics (v1)

  Timed events are naive wall-clock stored as UTC verbatim. All-day
  events use real dates; the form's end date is INCLUSIVE ("last day")
  and shifted to the exclusive storage form at this boundary.
  """
  use PhoenixKitWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Paths
  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixLiveCalendar.Utils.DateHelpers

  # Deterministic per-person palette for multi-calendar views. Complete
  # static class strings (Tailwind purge safety); paired text colors keep
  # titles readable on every hue.
  @owner_palette [
    {"bg-blue-600", "text-white"},
    {"bg-emerald-600", "text-white"},
    {"bg-amber-500", "text-black"},
    {"bg-rose-600", "text-white"},
    {"bg-violet-600", "text-white"},
    {"bg-cyan-600", "text-white"},
    {"bg-lime-600", "text-black"},
    {"bg-fuchsia-600", "text-white"},
    {"bg-orange-600", "text-white"},
    {"bg-teal-600", "text-white"},
    {"bg-indigo-600", "text-white"},
    {"bg-pink-500", "text-white"}
  ]

  # Rendered rows are capped; past this the panel asks to refine the search.
  @panel_row_cap 50

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    own_uuid = scope && Scope.user_uuid(scope)
    today = Date.utc_today()
    {from, until} = DateHelpers.visible_range(:month, today)

    can_view_others? =
      Scope.can?(scope, "calendar.view_others") or Scope.can?(scope, "calendar.edit_others")

    can_edit_others? = Scope.can?(scope, "calendar.edit_others")

    socket =
      socket
      |> assign(:page_title, Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar"))
      |> assign(:scope, scope)
      |> assign(:own_uuid, own_uuid)
      |> assign(:today, today)
      |> assign(:window, {from, until})
      |> assign(:can_view_others?, can_view_others?)
      |> assign(:can_edit_others?, can_edit_others?)
      |> assign(:people, if(can_view_others?, do: load_people(), else: []))
      |> assign(:window_counts, %{})
      |> assign(:people_query, "")
      |> assign(:show_event_modal, false)
      |> assign(:editing_event, nil)
      |> assign(:can_edit_event?, false)
      |> assign(:new_event_owner, nil)
      |> assign(:show_form_errors?, false)
      |> assign(:event_form, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    selected = sanitize_selection(socket, params["people"])

    socket =
      socket
      |> assign(:selected, selected)
      |> derive_selection_assigns()
      |> reload_events()
      |> reload_window_counts()

    {:noreply, socket}
  end

  # Parses ?people= into a safe, non-empty selection set. Unknown ids are
  # dropped; without view_others the URL is ignored entirely.
  defp sanitize_selection(socket, people_param) do
    own_uuid = socket.assigns.own_uuid

    cond do
      not socket.assigns.can_view_others? ->
        MapSet.new([own_uuid])

      people_param == "all" ->
        MapSet.new([own_uuid | Enum.map(socket.assigns.people, & &1.uuid)])

      is_binary(people_param) ->
        known = MapSet.new([own_uuid | Enum.map(socket.assigns.people, & &1.uuid)])

        people_param
        |> String.split(",", trim: true)
        |> Enum.filter(&MapSet.member?(known, &1))
        |> case do
          [] -> MapSet.new([own_uuid])
          uuids -> MapSet.new(uuids)
        end

      true ->
        MapSet.new([own_uuid])
    end
  end

  defp derive_selection_assigns(socket) do
    %{selected: selected, own_uuid: own_uuid, scope: scope} = socket.assigns

    single_owner =
      case MapSet.to_list(selected) do
        [uuid] -> uuid
        _ -> nil
      end

    read_only_badge? =
      cond do
        selected == MapSet.new([own_uuid]) -> false
        single_owner -> not Events.can_edit?(scope, single_owner)
        true -> not Scope.can?(scope, "calendar.edit_others")
      end

    socket
    |> assign(:single_owner, single_owner)
    |> assign(:can_edit_single?, single_owner != nil and Events.can_edit?(scope, single_owner))
    |> assign(:read_only_badge?, read_only_badge?)
  end

  # ── Calendar component callbacks (arrive as messages) ─────────────────────

  @impl true
  def handle_info({:calendar_range_change, %{start: from, end: until}}, socket) do
    socket =
      socket
      |> assign(:window, {from, until})
      |> reload_events()
      |> reload_window_counts()

    {:noreply, socket}
  end

  def handle_info({:calendar_date_click, %Date{} = date}, socket) do
    changeset =
      Event.changeset(%Event{}, %{
        "all_day" => "false",
        "starts_at" => DateTime.new!(date, ~T[09:00:00], "Etc/UTC"),
        "ends_at" => DateTime.new!(date, ~T[10:00:00], "Etc/UTC")
      })

    {:noreply, open_modal(socket, nil, changeset)}
  end

  def handle_info({:calendar_event_click, event_id}, socket) do
    case Events.get_event(socket.assigns.scope, event_id) do
      {:ok, event} ->
        {:noreply, open_modal(socket, event, Event.changeset(event, %{}))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, Gettext.gettext(PhoenixKitWeb.Gettext, "Event not found"))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── People panel events ─────────────────────────────────────────────────────
  #
  # Panel open/close is pure client-side (core PopoverPanel JS commands) —
  # only the interactions INSIDE the panel reach the server.

  @impl true
  def handle_event("search_people", %{"q" => query}, socket) do
    {:noreply, assign(socket, :people_query, query)}
  end

  def handle_event("toggle_person", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, uuid),
        do: MapSet.delete(selected, uuid),
        else: MapSet.put(selected, uuid)

    {:noreply, patch_selection(socket, selected)}
  end

  def handle_event("solo_person", %{"uuid" => uuid}, socket) do
    {:noreply, patch_selection(socket, MapSet.new([uuid]))}
  end

  def handle_event("select_me", _params, socket) do
    {:noreply, patch_selection(socket, MapSet.new([socket.assigns.own_uuid]))}
  end

  def handle_event("select_everyone", _params, socket) do
    all = MapSet.new([socket.assigns.own_uuid | Enum.map(socket.assigns.people, & &1.uuid)])
    {:noreply, patch_selection(socket, all)}
  end

  # ── Event modal events ──────────────────────────────────────────────────────

  def handle_event("new_event", _params, socket) do
    send(self(), {:calendar_date_click, socket.assigns.today})
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("validate_event", %{"event" => event_params} = params, socket) do
    # phx-change keeps the form synced (the all-day toggle swaps the
    # date/datetime inputs; the owner picker drives the off-view warning),
    # but validation errors stay HIDDEN until the first save attempt —
    # a changeset without an action renders no errors. After a failed
    # save they update live while the user fixes the form.
    action = if socket.assigns.show_form_errors?, do: :validate, else: nil

    changeset =
      (socket.assigns.editing_event || %Event{})
      |> Event.changeset(normalize_params(event_params))
      |> Map.put(:action, action)

    {:noreply,
     socket
     |> assign(:new_event_owner, sanitize_owner(socket, params["owner"]))
     |> assign(:event_form, to_form(changeset, as: "event"))}
  end

  def handle_event("save_event", %{"event" => event_params} = params, socket) do
    %{scope: scope, editing_event: editing} = socket.assigns
    event_params = normalize_params(event_params)

    result =
      case editing do
        %Event{} = event ->
          Events.update_event(scope, event, event_params)

        nil ->
          # target = picker value (edit_others holders) or the modal default;
          # sanitized to known people, authorized by the context either way
          owner_uuid =
            sanitize_owner(socket, params["owner"]) ||
              socket.assigns.new_event_owner ||
              socket.assigns.own_uuid

          Events.create_event(scope, owner_uuid, event_params)
      end

    case result do
      {:ok, _event} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Event saved"))
         |> close_modal()
         |> reload_events()
         |> reload_window_counts()}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "You are not allowed to edit this calendar")
         )
         |> close_modal()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:show_form_errors?, true)
         |> assign(:event_form, to_form(changeset, as: "event"))}
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
             |> reload_events()
             |> reload_window_counts()}

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

  # ── Selection / URL ─────────────────────────────────────────────────────────

  defp patch_selection(socket, selected) do
    own_only = MapSet.new([socket.assigns.own_uuid])
    # an empty set falls back to the own calendar — there is no "nothing" view
    selected = if MapSet.size(selected) == 0, do: own_only, else: selected

    push_patch(socket, to: Paths.people(people_param(socket, selected)))
  end

  # Compact URL forms: absent = {me}, "all" = every known calendar.
  defp people_param(socket, selected) do
    own_only = MapSet.new([socket.assigns.own_uuid])
    all = MapSet.new([socket.assigns.own_uuid | Enum.map(socket.assigns.people, & &1.uuid)])

    cond do
      MapSet.equal?(selected, own_only) -> nil
      MapSet.equal?(selected, all) -> "all"
      true -> selected |> MapSet.to_list() |> Enum.sort() |> Enum.join(",")
    end
  end

  # ── Data loading ────────────────────────────────────────────────────────────

  defp reload_events(socket) do
    %{scope: scope, selected: selected, window: {from, until}} = socket.assigns

    multi? = MapSet.size(selected) > 1

    events =
      case MapSet.to_list(selected) do
        [owner_uuid] ->
          case Events.list_events(scope, owner_uuid, from, until) do
            {:ok, events} -> events
            {:error, _} -> []
          end

        owner_uuids ->
          case Events.list_all_events(scope, from, until, owner_uuids: owner_uuids) do
            {:ok, events} -> events
            {:error, _} -> []
          end
      end

    assign(socket, :calendar_events, Enum.map(events, &to_lib_event(&1, multi?)))
  end

  defp reload_window_counts(socket) do
    if socket.assigns.can_view_others? do
      {from, until} = socket.assigns.window

      counts =
        case Events.count_events_by_owner(socket.assigns.scope, from, until) do
          {:ok, counts} -> counts
          {:error, _} -> %{}
        end

      assign(socket, :window_counts, counts)
    else
      socket
    end
  end

  # Single-calendar views keep each event's own color; multi-calendar
  # views tint by owner so a day cell reads as "who is booked".
  defp to_lib_event(%Event{} = event, multi?) do
    {color, text_color} =
      if multi? do
        owner_color(event.owner_uuid)
      else
        {event.color, nil}
      end

    {start_value, end_value} =
      if event.all_day,
        do: {event.starts_on, event.ends_on},
        else: {event.starts_at, event.ends_at}

    %PhoenixLiveCalendar.Event{
      id: event.uuid,
      title: event.title,
      start: start_value,
      end: end_value,
      all_day: event.all_day,
      color: color,
      text_color: text_color,
      description: event.description,
      location: event.location,
      status: status_atom(event.status)
    }
  end

  defp status_atom("cancelled"), do: :cancelled
  defp status_atom(_), do: :confirmed

  @doc false
  def owner_color(owner_uuid) do
    Enum.at(@owner_palette, :erlang.phash2(owner_uuid, length(@owner_palette)))
  end

  # All active users for the people panel — deliberately including users
  # WITHOUT calendar access (their history must stay reviewable).
  defp load_people do
    access_set = calendar_access_set()

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
        email: u.email,
        has_access?: MapSet.member?(access_set, u.uuid)
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

  defp filtered_people(people, query) do
    query = query |> String.trim() |> String.downcase()

    if query == "" do
      people
    else
      Enum.filter(people, fn p ->
        String.contains?(String.downcase(p.label), query) or
          String.contains?(String.downcase(p.email), query)
      end)
    end
  end

  # ── Modal helpers ───────────────────────────────────────────────────────────

  defp open_modal(socket, event, changeset) do
    # A NEW event is always creatable (at minimum on your own calendar);
    # an EXISTING event is authorized against its persisted owner.
    can_edit_event? =
      case event do
        nil -> true
        %Event{} -> Events.can_edit?(socket.assigns.scope, event.owner_uuid)
      end

    socket
    |> assign(:editing_event, event)
    |> assign(:can_edit_event?, can_edit_event?)
    |> assign(:new_event_owner, if(is_nil(event), do: default_new_owner(socket)))
    |> assign(:show_form_errors?, false)
    |> assign(:event_form, to_form(inclusive_end(changeset), as: "event"))
    |> assign(:show_event_modal, true)
  end

  # Creating defaults to the single viewed calendar when the viewer may
  # edit it, otherwise to their own calendar.
  defp default_new_owner(socket) do
    if socket.assigns.can_edit_single?,
      do: socket.assigns.single_owner,
      else: socket.assigns.own_uuid
  end

  # Only known people are acceptable targets, and only edit_others holders
  # may target anyone but themselves. The context re-authorizes on create —
  # this just keeps UI state (and the FK) clean.
  defp sanitize_owner(_socket, nil), do: nil

  defp sanitize_owner(socket, uuid) when is_binary(uuid) do
    %{own_uuid: own_uuid, can_edit_others?: can_edit_others?, people: people} = socket.assigns

    cond do
      uuid == own_uuid -> own_uuid
      can_edit_others? and Enum.any?(people, &(&1.uuid == uuid)) -> uuid
      true -> own_uuid
    end
  end

  defp close_modal(socket) do
    socket
    |> assign(:show_event_modal, false)
    |> assign(:editing_event, nil)
    |> assign(:can_edit_event?, false)
    |> assign(:new_event_owner, nil)
    |> assign(:show_form_errors?, false)
    |> assign(:event_form, nil)
  end

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

  # ── Display helpers ─────────────────────────────────────────────────────────

  defp header_title(assigns) do
    %{selected: selected, own_uuid: own_uuid, single_owner: single_owner, people: people} =
      assigns

    cond do
      MapSet.equal?(selected, MapSet.new([own_uuid])) ->
        Gettext.gettext(PhoenixKitWeb.Gettext, "My calendar")

      single_owner ->
        case Enum.find(people, &(&1.uuid == single_owner)) do
          nil -> Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar")
          person -> person.label
        end

      true ->
        Gettext.gettext(PhoenixKitWeb.Gettext, "Viewing %{count} calendars",
          count: MapSet.size(selected)
        )
    end
  end

  defp owner_options(people, own_uuid) do
    me = {Gettext.gettext(PhoenixKitWeb.Gettext, "Me"), own_uuid}
    others = people |> Enum.reject(&(&1.uuid == own_uuid)) |> Enum.map(&{&1.label, &1.uuid})
    [me | others]
  end

  defp owner_label(people, own_uuid, uuid) do
    cond do
      uuid == own_uuid -> Gettext.gettext(PhoenixKitWeb.Gettext, "Me")
      person = Enum.find(people, &(&1.uuid == uuid)) -> person.label
      true -> Gettext.gettext(PhoenixKitWeb.Gettext, "Unknown user")
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-4 sm:py-5 gap-3">
      <%!-- Toolbar: what you're viewing + actions. mb-0: the wrapper's flex
           gap is the single source of header/calendar spacing (the header's
           default margin would compound with it and strand the title). --%>
      <.admin_page_header class="mb-0">
        <div class="flex items-center gap-3 min-w-0">
          <h1 class="text-2xl font-bold truncate">
            <.icon name="hero-calendar-days" class="w-7 h-7 inline-block mr-1" />
            {header_title(assigns)}
          </h1>
          <span :if={@read_only_badge?} class="badge badge-warning gap-1 shrink-0">
            <.icon name="hero-eye" class="w-3.5 h-3.5" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Read only")}
          </span>
        </div>
        <:actions>
          <%!-- Calendars panel toggle — view_others holders only. Opens
               INSTANTLY: client-side JS toggle, no server round-trip. --%>
          <div :if={@can_view_others?} class="relative">
            <button
              type="button"
              phx-click={toggle_popover("calendar-people-panel")}
              class="btn btn-sm gap-2 w-full sm:w-auto"
            >
              <.icon name="hero-users" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Calendars")}
              <span class="badge badge-sm badge-primary">{MapSet.size(@selected)}</span>
            </button>

            <.people_panel
              people={filtered_people(@people, @people_query)}
              people_query={@people_query}
              selected={@selected}
              own_uuid={@own_uuid}
              window_counts={@window_counts}
            />
          </div>

          <button phx-click="new_event" class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New event")}
          </button>
        </:actions>
      </.admin_page_header>

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
            <% @can_edit_event? -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit event")}
            <% true -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Event")}
          <% end %>
        </:title>

        <%!-- Whose calendar an EXISTING event belongs to (immutable) --%>
        <div
          :if={@editing_event}
          class="flex items-center gap-2 mb-3 text-sm text-base-content/70"
        >
          <span class={[
            "w-2.5 h-2.5 rounded-full",
            elem(owner_color(@editing_event.owner_uuid), 0)
          ]} />
          {owner_label(@people, @own_uuid, @editing_event.owner_uuid)}
        </div>

        <%= if @can_edit_event? do %>
          <.form
            for={@event_form}
            id="calendar-event-form"
            phx-change="validate_event"
            phx-submit="save_event"
            class="space-y-3"
          >
            <%!-- Whose calendar the NEW event goes on. Not a changeset field
                 by design (owner is never cast); the context authorizes the
                 explicit argument on create. --%>
            <div :if={is_nil(@editing_event)} class="space-y-2">
              <%= if @can_edit_others? do %>
                <.select
                  name="owner"
                  value={@new_event_owner}
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar")}
                  options={owner_options(@people, @own_uuid)}
                />
              <% else %>
                <p class="text-sm text-base-content/70">
                  <span class={["w-2.5 h-2.5 rounded-full inline-block mr-1", elem(owner_color(@own_uuid), 0)]} />
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "On your calendar")}
                </p>
              <% end %>

              <div
                :if={@new_event_owner && not MapSet.member?(@selected, @new_event_owner)}
                class="alert alert-warning py-2 text-sm"
              >
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                {Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "%{name} isn't shown in your current view — the event will be created but won't appear here.",
                  name: owner_label(@people, @own_uuid, @new_event_owner)
                )}
              </div>
            </div>

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
            :if={@can_edit_event? and not is_nil(@editing_event)}
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
            :if={@can_edit_event?}
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

  # ── People panel component ─────────────────────────────────────────────────

  attr(:people, :list, required: true)
  attr(:people_query, :string, required: true)
  attr(:selected, :any, required: true)
  attr(:own_uuid, :string, required: true)
  attr(:window_counts, :map, required: true)

  defp people_panel(assigns) do
    assigns =
      assigns
      |> assign(:visible, Enum.take(assigns.people, @panel_row_cap))
      |> assign(:overflow, max(length(assigns.people) - @panel_row_cap, 0))

    ~H"""
    <.popover_panel id="calendar-people-panel">
      <div class="card-body p-3 gap-2">
          <div class="flex items-center gap-2">
            <form
              id="calendar-people-search"
              phx-change="search_people"
              class="grow"
              onsubmit="return false;"
            >
              <label class="input input-sm w-full">
                <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
                <input
                  type="search"
                  name="q"
                  value={@people_query}
                  phx-debounce="300"
                  placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Search people…")}
                  autocomplete="off"
                />
                <%!-- spinner while the (debounced) search round-trip is in
                     flight — LV puts phx-change-loading on the form --%>
                <span class="loading loading-spinner loading-xs invisible [.phx-change-loading_&]:visible" />
              </label>
            </form>
            <button
              type="button"
              phx-click={hide_popover("calendar-people-panel")}
              class="btn btn-ghost btn-xs btn-circle"
              aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Close")}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="flex gap-1.5">
            <button type="button" phx-click="select_me" class="btn btn-xs btn-outline">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Me")}
            </button>
            <button type="button" phx-click="select_everyone" class="btn btn-xs btn-outline">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Everyone")}
            </button>
          </div>

          <ul class="max-h-80 overflow-y-auto divide-y divide-base-content/5">
            <%!-- the viewer's own calendar always heads the list --%>
            <.person_row
              uuid={@own_uuid}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Me")}
              selected={MapSet.member?(@selected, @own_uuid)}
              has_access?={true}
              empty?={Map.get(@window_counts, @own_uuid, 0) == 0}
            />
            <.person_row
              :for={person <- @visible}
              :if={person.uuid != @own_uuid}
              uuid={person.uuid}
              label={person.label}
              selected={MapSet.member?(@selected, person.uuid)}
              has_access?={person.has_access?}
              empty?={Map.get(@window_counts, person.uuid, 0) == 0}
            />
            <li :if={@overflow > 0} class="py-2 text-center text-xs text-base-content/50">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "%{count} more — refine your search",
                count: @overflow
              )}
            </li>
            <li
              :if={@visible == [] and @people_query != ""}
              class="py-2 text-center text-xs text-base-content/50"
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "No people match")}
            </li>
          </ul>
      </div>
    </.popover_panel>
    """
  end

  attr(:uuid, :string, required: true)
  attr(:label, :string, required: true)
  attr(:selected, :boolean, required: true)
  attr(:has_access?, :boolean, required: true)
  attr(:empty?, :boolean, required: true)

  defp person_row(assigns) do
    ~H"""
    <li class="flex items-center gap-2 py-1.5 px-1">
      <input
        type="checkbox"
        class={[
          "checkbox checkbox-sm checkbox-primary",
          "[&.phx-click-loading]:opacity-40 [&.phx-click-loading]:animate-pulse"
        ]}
        checked={@selected}
        phx-click="toggle_person"
        phx-value-uuid={@uuid}
        aria-label={@label}
      />
      <span class={["w-2.5 h-2.5 rounded-full shrink-0", elem(owner_color(@uuid), 0)]} />
      <button
        type="button"
        phx-click="solo_person"
        phx-value-uuid={@uuid}
        class="text-sm text-left truncate grow hover:underline"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Show only this calendar")}
      >
        {@label}
      </button>
      <span
        :if={not @has_access?}
        class="tooltip tooltip-left shrink-0"
        data-tip={Gettext.gettext(PhoenixKitWeb.Gettext, "No calendar access — history only")}
      >
        <.icon name="hero-lock-closed" class="w-3.5 h-3.5 text-base-content/40" />
      </span>
      <span :if={@empty?} class="badge badge-ghost badge-xs shrink-0">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "empty")}
      </span>
    </li>
    """
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
