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

  ## Time semantics

  Timed events are stored in UTC and shown/entered in the viewer's
  timezone (core's offset-hours model: `user_timezone` column → site
  "time_zone" setting → UTC). When the target calendar's owner sits in a
  different offset, the modal says so and offers a checkbox to switch
  the entry frame to THEIR timezone — toggling re-renders the same
  instant, never reinterprets the digits. All-day events use real dates
  (no timezone); the form's end date is INCLUSIVE ("last day") and
  shifted to the exclusive storage form at this boundary.
  """
  use PhoenixKitWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: DateUtils
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Participants
  alias PhoenixKitCalendar.Paths
  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixKitCalendar.Sources
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

  # Explicit text pairing for the static (non-daisyUI) event colors — the
  # lib's Safe.infer_text_color/1 only knows the semantic set.
  @static_text_colors %{
    "bg-orange-600" => "text-white",
    "bg-pink-500" => "text-white",
    "bg-violet-600" => "text-white",
    "bg-lime-600" => "text-black"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    own_uuid = scope && Scope.user_uuid(scope)
    today = Date.utc_today()
    {from, until} = DateHelpers.visible_range(:month, today)

    can_view_others? =
      Scope.can?(scope, "calendar.view_others") or Scope.can?(scope, "calendar.edit_others")

    can_edit_others? = Scope.can?(scope, "calendar.edit_others")

    # Offset-hours strings, core's timezone model (user column → site
    # "time_zone" setting → "0"). Storage is UTC; every wall-clock the
    # viewer sees or types is converted through these.
    site_tz = site_timezone()
    viewer_tz = viewer_timezone(scope, site_tz)

    socket =
      socket
      |> assign(:page_title, Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar"))
      |> assign(:scope, scope)
      |> assign(:own_uuid, own_uuid)
      |> assign(:site_tz, site_tz)
      |> assign(:viewer_tz, viewer_tz)
      |> assign(:today, today)
      |> assign(:window, {from, until})
      |> assign(:can_view_others?, can_view_others?)
      |> assign(:can_edit_others?, can_edit_others?)
      |> assign(:people, if(can_view_others?, do: load_people(site_tz), else: []))
      |> assign(:window_counts, %{})
      |> assign(:people_query, "")
      |> assign(:show_event_modal, false)
      |> assign(:editing_event, nil)
      |> assign(:can_edit_event?, false)
      |> assign(:new_event_owner, nil)
      |> assign(:show_form_errors?, false)
      |> assign(:event_form, nil)
      |> assign(:input_tz, viewer_tz)
      |> assign(:modal_owner_tz, viewer_tz)
      |> assign(:owner_tz_differs?, false)
      |> assign(:enter_in_owner_tz?, false)
      |> assign(:participant_sources, Sources.available_participant_sources(scope))
      |> assign(:location_options, Sources.list_locations())
      |> assign(:pending_participants, [])

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
    # default 09:00–10:00 in the VIEWER's timezone, stored as UTC
    tz = socket.assigns.viewer_tz
    {:ok, starts_at} = DateUtils.parse_datetime_local("#{Date.to_iso8601(date)}T09:00", tz)
    {:ok, ends_at} = DateUtils.parse_datetime_local("#{Date.to_iso8601(date)}T10:00", tz)

    changeset =
      Event.changeset(%Event{}, %{
        "all_day" => "false",
        "starts_at" => starts_at,
        "ends_at" => ends_at
      })

    {:noreply, open_modal(socket, nil, changeset)}
  end

  def handle_info({:calendar_event_click, event_id}, socket) do
    case Events.get_event(socket.assigns.scope, event_id) do
      {:ok, event} ->
        {:noreply, open_modal(socket, event, Event.changeset(event, %{}))}

      {:error, _} ->
        # the click already opened the kept-in-DOM dialog client-side —
        # tell it to close since there is nothing to show
        {:noreply,
         socket
         |> push_event("pk:dialog-close", %{id: "calendar-event-modal"})
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Event not found"))}
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

  # Both pickers are core SearchPicker hooks: the dropdown is client-rendered
  # (instant); these handlers only run the search and answer via push_event.
  def handle_event("participant_search", %{"q" => query}, socket) when is_binary(query) do
    query = String.trim(query)
    pending_keys = MapSet.new(socket.assigns.pending_participants, &participant_key/1)

    results =
      socket.assigns.scope
      |> Sources.search_participants(query)
      |> Enum.flat_map(fn {source, results} ->
        results
        |> Enum.reject(&MapSet.member?(pending_keys, participant_key(&1)))
        |> Enum.map(fn r ->
          %{
            kind: r.kind,
            uuid: r.target_uuid,
            label: r.display_name,
            sublabel: source_label(source),
            icon: kind_icon(r.kind)
          }
        end)
      end)

    {:noreply,
     push_event(socket, "calendar_participant_results", %{
       q: query,
       results: results,
       has_more: false
     })}
  end

  def handle_event("location_search", %{"q" => query} = params, socket)
      when is_binary(query) do
    query = String.trim(query)
    down = String.downcase(query)
    limit = parse_limit(params["limit"])

    matches =
      Enum.filter(socket.assigns.location_options, fn loc ->
        down == "" or String.contains?(String.downcase(loc.name), down)
      end)

    results =
      matches
      |> Enum.take(limit)
      |> Enum.map(fn loc ->
        %{kind: "location", uuid: loc.uuid, label: loc.name, icon: "hero-map-pin"}
      end)

    {:noreply,
     push_event(socket, "calendar_location_results", %{
       q: query,
       results: results,
       has_more: length(matches) > limit
     })}
  end

  def handle_event("add_participant", %{"kind" => kind, "uuid" => uuid, "label" => name}, socket)
      when is_binary(kind) and is_binary(name) do
    # the context re-validates on save; this guard keeps the UI honest
    socket =
      if Participants.kind_allowed?(socket.assigns.scope, kind) do
        # free_text never carries a target; the context canonicalizes the
        # display_name for every other kind at save time regardless
        target = if kind == "free_text", do: nil, else: uuid
        append_participant(socket, %{kind: kind, target_uuid: target, display_name: name})
      else
        socket
      end

    # confirm in every branch so the hook clears instead of spinning
    {:noreply, push_event(socket, "calendar_participant_staged", %{})}
  end

  def handle_event("add_free_text_participant", %{"name" => name}, socket)
      when is_binary(name) do
    name = String.trim(name)

    socket =
      if name == "" do
        socket
      else
        append_participant(socket, %{kind: "free_text", target_uuid: nil, display_name: name})
      end

    {:noreply, push_event(socket, "calendar_participant_staged", %{})}
  end

  def handle_event("remove_participant", %{"idx" => idx}, socket) do
    pending = socket.assigns.pending_participants

    case Integer.parse(to_string(idx)) do
      {i, ""} when i >= 0 and i < length(pending) ->
        {:noreply, assign(socket, :pending_participants, List.delete_at(pending, i))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_event", %{"event" => event_params} = params, socket) do
    # phx-change keeps the form synced (the all-day toggle swaps the
    # date/datetime inputs; the owner picker drives the off-view warning),
    # but validation errors stay HIDDEN until the first save attempt —
    # a changeset without an action renders no errors. After a failed
    # save they update live while the user fixes the form.
    action = if socket.assigns.show_form_errors?, do: :validate, else: nil

    # the timed values were typed in the frame they were DISPLAYED in —
    # convert with it BEFORE recomputing the frame, or toggling the
    # timezone checkbox would shift the instant instead of the digits
    entry_tz = socket.assigns.input_tz

    changeset =
      (socket.assigns.editing_event || %Event{})
      |> Event.changeset(
        event_params
        |> normalize_params()
        |> localize_times(entry_tz)
        |> link_location(socket.assigns.location_options)
      )
      |> Map.put(:action, action)

    {:noreply,
     socket
     |> assign(:new_event_owner, sanitize_owner(socket, params["owner"]))
     |> assign_tz_frame(params["owner_tz_entry"])
     |> assign(:event_form, to_form(changeset, as: "event"))}
  end

  def handle_event("save_event", %{"event" => event_params} = params, socket) do
    %{scope: scope, editing_event: editing} = socket.assigns

    event_params =
      event_params
      |> normalize_params()
      |> localize_times(socket.assigns.input_tz)
      |> link_location(socket.assigns.location_options)

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
      {:ok, event} ->
        {socket, participants_ok?} = save_participants(socket, event)

        socket =
          if participants_ok? do
            put_flash(socket, :info, Gettext.gettext(PhoenixKitWeb.Gettext, "Event saved"))
          else
            socket
          end

        {:noreply,
         socket
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

    tz = socket.assigns.viewer_tz
    assign(socket, :calendar_events, Enum.map(events, &to_lib_event(&1, multi?, tz)))
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
  defp to_lib_event(%Event{} = event, multi?, viewer_tz) do
    {color, text_color} =
      if multi? do
        owner_color(event.owner_uuid)
      else
        {event.color, Map.get(@static_text_colors, event.color)}
      end

    # timed events are stored UTC and rendered in the VIEWER's offset
    # (display-only shift; all-day dates need none)
    {start_value, end_value} =
      if event.all_day,
        do: {event.starts_on, event.ends_on},
        else:
          {DateUtils.shift_to_offset(event.starts_at, viewer_tz),
           DateUtils.shift_to_offset(event.ends_at, viewer_tz)}

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
  defp load_people(site_tz) do
    access_set = calendar_access_set()

    from(u in PhoenixKit.Users.Auth.User,
      where: u.is_active == true,
      order_by: [asc: u.email],
      select: %{
        uuid: u.uuid,
        email: u.email,
        first_name: u.first_name,
        last_name: u.last_name,
        user_timezone: u.user_timezone
      }
    )
    |> RepoHelper.repo().all()
    |> Enum.map(fn u ->
      %{
        uuid: u.uuid,
        label: display_name(u),
        email: u.email,
        has_access?: MapSet.member?(access_set, u.uuid),
        # effective offset: personal setting, else the site default
        tz: u.user_timezone || site_tz
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

    pending =
      case event do
        nil ->
          []

        %Event{} = event ->
          event.uuid
          |> Participants.list_for_event()
          |> Enum.map(
            &%{kind: &1.kind, target_uuid: &1.target_uuid, display_name: &1.display_name}
          )
      end

    socket
    |> assign(:editing_event, event)
    |> assign(:can_edit_event?, can_edit_event?)
    |> assign(:new_event_owner, if(is_nil(event), do: default_new_owner(socket)))
    |> assign(:show_form_errors?, false)
    |> assign(:pending_participants, pending)
    |> assign(:event_form, to_form(changeset, as: "event"))
    # fresh frame each open: the viewer's timezone until the checkbox opts
    # into the owner's
    |> assign_tz_frame(nil)
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
    |> assign(:pending_participants, [])
    |> assign(:event_form, nil)
  end

  # ── Timezones ───────────────────────────────────────────────────────────
  #
  # Core's model is OFFSET-HOURS STRINGS ("0", "3", "-5"): the user's
  # `user_timezone` column, falling back to the site "time_zone" setting.
  # Events are STORED in UTC; the form displays/accepts wall-clock in an
  # "input frame" — normally the viewer's offset, switchable to the target
  # calendar owner's offset when the two differ (the modal checkbox). The
  # changeset always holds UTC, so toggling the frame re-renders the same
  # instant in the other offset instead of silently reinterpreting digits.

  defp site_timezone do
    PhoenixKit.Settings.get_setting("time_zone", "0")
  rescue
    _ -> "0"
  end

  defp viewer_timezone(scope, site_tz) do
    case scope && scope.user do
      %{user_timezone: tz} when is_binary(tz) and tz != "" -> tz
      _ -> site_tz
    end
  end

  # The effective offset of a calendar owner: self → viewer; anyone else →
  # the people list (all active users, already resolved), with a direct
  # lookup as the fallback for completeness.
  defp owner_timezone(socket, nil), do: socket.assigns.viewer_tz

  defp owner_timezone(socket, owner_uuid) do
    %{own_uuid: own_uuid, people: people, site_tz: site_tz} = socket.assigns

    cond do
      owner_uuid == own_uuid ->
        socket.assigns.viewer_tz

      person = Enum.find(people, &(&1.uuid == owner_uuid)) ->
        person.tz

      true ->
        from(u in PhoenixKit.Users.Auth.User,
          where: u.uuid == ^owner_uuid,
          select: u.user_timezone
        )
        |> RepoHelper.repo().one()
        |> case do
          tz when is_binary(tz) and tz != "" -> tz
          _ -> site_tz
        end
    end
  rescue
    _ -> socket.assigns.viewer_tz
  end

  defp tz_differs?(a, b), do: DateUtils.offset_to_seconds(a) != DateUtils.offset_to_seconds(b)

  # Recomputes the modal's timezone frame from the current target owner +
  # the "show in their timezone" checkbox. Runs at open and on every
  # validate (the owner picker can change the target mid-edit).
  defp assign_tz_frame(socket, owner_tz_entry_param) do
    owner_uuid =
      case socket.assigns.editing_event do
        %Event{owner_uuid: uuid} -> uuid
        nil -> socket.assigns.new_event_owner
      end

    owner_tz = owner_timezone(socket, owner_uuid)
    differs? = tz_differs?(owner_tz, socket.assigns.viewer_tz)
    enter_in_owner? = differs? and owner_tz_entry_param == "true"

    socket
    |> assign(:modal_owner_tz, owner_tz)
    |> assign(:owner_tz_differs?, differs?)
    |> assign(:enter_in_owner_tz?, enter_in_owner?)
    |> assign(:input_tz, if(enter_in_owner?, do: owner_tz, else: socket.assigns.viewer_tz))
  end

  # Converts the timed pair from the input frame's wall-clock to UTC ISO
  # strings for the changeset. `tz` MUST be the frame the values were
  # DISPLAYED in when the user typed them (assigns.input_tz before any
  # frame recompute), or a checkbox toggle would shift the instant.
  defp localize_times(params, tz) do
    params
    |> convert_time("starts_at", tz)
    |> convert_time("ends_at", tz)
  end

  defp convert_time(params, key, tz) do
    case params[key] do
      value when is_binary(value) and value != "" ->
        case DateUtils.parse_datetime_local(value, tz) do
          {:ok, dt} -> Map.put(params, key, DateTime.to_iso8601(dt))
          # leave malformed input for the changeset to reject
          _ -> params
        end

      _ ->
        params
    end
  end

  # UTC changeset value → the input frame's wall-clock for datetime-local.
  # Mid-edit the form field yields the raw PARAM (the UTC ISO string that
  # localize_times produced) rather than the cast DateTime — parse those
  # too. A string WITHOUT an offset is unconverted junk from a failed
  # parse; show it as typed so the user can correct it.
  defp datetime_local_value(%DateTime{} = dt, tz), do: DateUtils.format_datetime_local(dt, tz)

  defp datetime_local_value(value, tz) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateUtils.format_datetime_local(dt, tz)
      _ -> value
    end
  end

  defp datetime_local_value(value, _tz), do: value

  # "+3" / "0" / "-5.5" → a compact UTC±N label for the indicator row.
  defp tz_label(tz) do
    case Float.parse(to_string(tz)) do
      {h, _} when h > 0 -> "UTC+#{format_offset(h)}"
      {h, _} when h < 0 -> "UTC-#{format_offset(abs(h))}"
      _ -> "UTC"
    end
  end

  defp format_offset(h) do
    if h == trunc(h), do: Integer.to_string(trunc(h)), else: Float.to_string(h)
  end

  # (The changeset always holds the EXCLUSIVE end — the inclusive "last
  # day" conversion happens ONLY at render, via inclusive_end_display/1.
  # A changeset-level shift here would stack with it: the edit form would
  # show a day short and an untouched save would shrink the event by one
  # day per open/save cycle.)

  # Toggling "All day" carries the values ACROSS the mode switch instead of
  # presenting empty fields: the date pair derives from the datetime pair
  # (and vice versa, with default working hours). Runs before the
  # display-inclusive -> storage-exclusive end-date shift.
  defp normalize_params(%{"all_day" => all_day} = params)
       when all_day in [true, "true", "on"] do
    params
    |> carry_dates_from_times()
    |> shift_inclusive_end()
  end

  defp normalize_params(params), do: carry_times_from_dates(params)

  defp carry_dates_from_times(params) do
    params
    |> carry(fn -> {"starts_on", date_part(params["starts_at"])} end)
    |> carry(fn ->
      {"ends_on", date_part(params["ends_at"]) || date_part(params["starts_at"])}
    end)
  end

  defp carry_times_from_dates(params) do
    params
    |> carry(fn -> {"starts_at", with_time(params["starts_on"], "09:00")} end)
    |> carry(fn ->
      # display ends_on is inclusive; a same-day event ends an hour later
      {"ends_at", with_time(params["ends_on"] || params["starts_on"], "10:00")}
    end)
  end

  # fills `key` only when it is absent/blank in the params
  defp carry(params, fun) do
    {key, derived} = fun.()

    if params[key] in [nil, ""] and is_binary(derived) do
      Map.put(params, key, derived)
    else
      params
    end
  end

  defp date_part(value) when is_binary(value) do
    case String.split(value, "T", parts: 2) do
      [date, _time] -> date
      _ -> nil
    end
  end

  defp date_part(_), do: nil

  defp with_time(date, time) when is_binary(date) and date != "", do: "#{date}T#{time}:00"
  defp with_time(_, _), do: nil

  # The changeset (and DB) hold the EXCLUSIVE end; the form shows the
  # inclusive "last day". Rendering the raw changeset value would display
  # the exclusive date — off by one, and each validate would shift the
  # round-tripped value another day.
  defp inclusive_end_display(%Date{} = date), do: Date.add(date, -1)

  defp inclusive_end_display(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(Date.add(date, -1))
      _ -> value
    end
  end

  defp inclusive_end_display(value), do: value

  defp shift_inclusive_end(params) do
    case Date.from_iso8601(params["ends_on"] || "") do
      {:ok, last_day} -> Map.put(params, "ends_on", Date.to_iso8601(Date.add(last_day, 1)))
      _ -> params
    end
  end

  # When the typed location exactly matches a stored location's name (the
  # datalist suggestion was picked), link it; any other text clears the link
  # and stays free-form. The context re-snapshots the name from the uuid.
  defp link_location(params, location_options) do
    case Enum.find(location_options, &(&1.name == String.trim(params["location"] || ""))) do
      nil -> Map.put(params, "location_uuid", nil)
      loc -> Map.put(params, "location_uuid", loc.uuid)
    end
  end

  defp participant_key(%{kind: "free_text", display_name: name}),
    do: {"free_text", String.downcase(name)}

  defp participant_key(%{kind: kind, target_uuid: target}), do: {kind, to_string(target)}

  defp append_participant(socket, entry) do
    pending = socket.assigns.pending_participants
    keys = MapSet.new(pending, &participant_key/1)

    pending =
      if MapSet.member?(keys, participant_key(entry)), do: pending, else: pending ++ [entry]

    socket
    |> assign(:pending_participants, pending)
  end

  defp save_participants(socket, event) do
    case Participants.replace_participants(
           socket.assigns.scope,
           event,
           socket.assigns.pending_participants
         ) do
      {:ok, _} ->
        {socket, true}

      {:error, _} ->
        {put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitWeb.Gettext,
             "The event was saved, but its participants could not be — please reopen it and try again"
           )
         ), false}
    end
  end

  # The SearchPicker hook grows its `limit` by 8 per "Load more" click;
  # bound it so a forged payload can't request an absurd page.
  defp parse_limit(n) when is_integer(n), do: n |> max(8) |> min(60)

  defp parse_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> parse_limit(i)
      _ -> 8
    end
  end

  defp parse_limit(_), do: 8

  defp kind_icon("user"), do: "hero-user"
  defp kind_icon("staff_person"), do: "hero-identification"
  defp kind_icon("crm_contact"), do: "hero-user-circle"
  defp kind_icon("crm_company"), do: "hero-building-office"
  defp kind_icon(_free_text), do: "hero-pencil"

  defp source_label(:users), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Users")
  defp source_label(:staff), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")
  defp source_label(:crm_contacts), do: Gettext.gettext(PhoenixKitWeb.Gettext, "CRM contacts")
  defp source_label(:crm_companies), do: Gettext.gettext(PhoenixKitWeb.Gettext, "CRM companies")

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

          <%!-- The dialog opens the same frame as the click (pk:dialog-show);
               the server round-trip fills the form in behind a skeleton. --%>
          <button
            phx-click={
              JS.dispatch("pk:dialog-show", to: "#calendar-event-modal") |> JS.push("new_event")
            }
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New event")}
          </button>
        </:actions>
      </.admin_page_header>

      <%!-- The month calendar (server-rendered). PkDialogTrigger makes event
           chips + day cells open the modal INSTANTLY (client dispatch); the
           matching server event then loads the real content. The "+N more"
           link has its own phx-click and doesn't match — it opens the lib's
           popover, not our modal. --%>
      <div
        id="calendar-grid-trigger"
        phx-hook="PkDialogTrigger"
        data-dialog="calendar-event-modal"
        data-trigger=".cal-event, .cal-multiday-bar, .cal-day-cell"
        class="card bg-base-100 shadow"
      >
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

      <%!-- Event create/edit/details modal. Kept in the DOM so triggers can
           open it client-side the same frame as the click; until the server
           round-trip lands (@show_event_modal), the body is a skeleton. --%>
      <.modal
        id="calendar-event-modal"
        keep_in_dom
        show={@show_event_modal}
        on_close="close_modal"
        max_width="2xl"
      >
        <:title>
          <%= cond do %>
            <% not @show_event_modal -> %>
              <span class="inline-block w-28 h-5 bg-base-content/10 rounded animate-pulse"></span>
            <% is_nil(@editing_event) -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "New event")}
            <% @can_edit_event? -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit event")}
            <% true -> %>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Event")}
          <% end %>
        </:title>

        <%= if @show_event_modal do %>

        <%!-- Whose calendar an EXISTING event belongs to (immutable). Shown
             as a labeled read-only field, and only when it carries real
             information — someone else's event, or a viewer who manages
             several calendars. Your own event on your own calendar says
             nothing. --%>
        <div
          :if={
            @editing_event &&
              (@editing_event.owner_uuid != @own_uuid or @can_edit_others?)
          }
          class="mb-3"
        >
          <span class="label">
            <span class="label-text font-semibold">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar")}
            </span>
          </span>
          <div class="flex items-center gap-2 px-3 py-2 rounded-lg border border-base-content/10 bg-base-200/50 text-sm">
            <span class={[
              "w-2.5 h-2.5 rounded-full",
              elem(owner_color(@editing_event.owner_uuid), 0)
            ]} />
            {owner_label(@people, @own_uuid, @editing_event.owner_uuid)}
          </div>
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
              <%!-- Without edit_others there is nothing to choose — the event
                   goes on your calendar and the row would be noise. --%>
              <.select
                :if={@can_edit_others?}
                name="owner"
                value={@new_event_owner}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Calendar")}
                options={owner_options(@people, @own_uuid)}
              />

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
                <%!-- storage is exclusive; the field displays the inclusive
                     last day (the explicit value overrides the field's) --%>
                <.input
                  field={@event_form[:ends_on]}
                  type="date"
                  value={inclusive_end_display(@event_form[:ends_on].value)}
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "End date (last day)")}
                />
              </div>
            <% else %>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <%!-- stored in UTC; shown/typed in the input frame --%>
                <.input
                  field={@event_form[:starts_at]}
                  type="datetime-local"
                  value={datetime_local_value(@event_form[:starts_at].value, @input_tz)}
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Starts")}
                />
                <.input
                  field={@event_form[:ends_at]}
                  type="datetime-local"
                  value={datetime_local_value(@event_form[:ends_at].value, @input_tz)}
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Ends")}
                />
              </div>

              <%!-- Cross-timezone indicator: only when the target calendar's
                   owner sits in a different offset than the viewer. The
                   checkbox switches the frame the times above are shown and
                   entered in — the stored instant never changes on toggle. --%>
              <div :if={@owner_tz_differs?} class="alert alert-info py-2 text-sm flex-wrap gap-2">
                <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                <span>
                  {Gettext.gettext(
                    PhoenixKitWeb.Gettext,
                    "%{name} is in %{owner_tz} — you are in %{viewer_tz}. Times are shown in %{frame}.",
                    name:
                      owner_label(
                        @people,
                        @own_uuid,
                        (@editing_event && @editing_event.owner_uuid) || @new_event_owner
                      ),
                    owner_tz: tz_label(@modal_owner_tz),
                    viewer_tz: tz_label(@viewer_tz),
                    frame:
                      if(@enter_in_owner_tz?,
                        do: Gettext.gettext(PhoenixKitWeb.Gettext, "their timezone"),
                        else: Gettext.gettext(PhoenixKitWeb.Gettext, "your timezone")
                      )
                  )}
                </span>
                <label class="flex items-center gap-2 cursor-pointer whitespace-nowrap">
                  <input
                    type="checkbox"
                    name="owner_tz_entry"
                    value="true"
                    checked={@enter_in_owner_tz?}
                    class="checkbox checkbox-xs"
                  />
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Use their timezone")}
                </label>
              </div>
            <% end %>

            <%= if @location_options != [] do %>
              <%!-- Stored-locations picker (core SearchPicker, single-select):
                   opens the list on click, filters as you type; a pick just
                   sets the text — link_location maps exact name → uuid. --%>
              <div>
                <.label for="calendar-location-picker">
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Location")}
                </.label>
                <.search_picker
                  id="calendar-location-picker"
                  dropdown_id="calendar-location-dropdown"
                  mode="single"
                  name={@event_form[:location].name}
                  value={@event_form[:location].value}
                  search_event="location_search"
                  results_event="calendar_location_results"
                  searching_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Searching…")}
                  more_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Load more")}
                  loading_more_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Loading…")}
                  data-search-on-focus
                  phx-debounce="300"
                />
              </div>
            <% else %>
              <.input
                field={@event_form[:location]}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Location")}
              />
            <% end %>
            <.textarea
              field={@event_form[:description]}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
            />

            <%!-- Color: radio swatches (sr-only inputs, ring on the checked
                 dot) + a live chip previewing how the event reads on the
                 grid. "Default" is the distinct slashed swatch. --%>
            <fieldset>
              <legend class="label">
                <span class="label-text font-semibold">
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Color")}
                </span>
              </legend>
              <div class="flex flex-wrap items-center gap-2">
                <label class="cursor-pointer" title={Gettext.gettext(PhoenixKitWeb.Gettext, "Default")}>
                  <input
                    type="radio"
                    name={@event_form[:color].name}
                    value=""
                    checked={color_value(@event_form) == ""}
                    class="sr-only peer"
                  />
                  <span class="relative block w-7 h-7 rounded-full border-2 border-base-content/20 bg-base-100 overflow-hidden peer-checked:ring-2 peer-checked:ring-primary peer-checked:ring-offset-2 peer-checked:ring-offset-base-100 peer-focus-visible:ring-2 peer-focus-visible:ring-primary">
                    <span class="absolute left-1/2 top-1/2 w-8 h-0.5 bg-base-content/30 -translate-x-1/2 -translate-y-1/2 rotate-45">
                    </span>
                  </span>
                  <span class="sr-only">{Gettext.gettext(PhoenixKitWeb.Gettext, "Default")}</span>
                </label>
                <label :for={choice <- color_choices()} class="cursor-pointer" title={choice.label}>
                  <input
                    type="radio"
                    name={@event_form[:color].name}
                    value={choice.value}
                    checked={color_value(@event_form) == choice.value}
                    class="sr-only peer"
                  />
                  <span class={[
                    "block w-7 h-7 rounded-full border border-base-content/10 peer-checked:ring-2 peer-checked:ring-primary peer-checked:ring-offset-2 peer-checked:ring-offset-base-100 peer-focus-visible:ring-2 peer-focus-visible:ring-primary",
                    choice.value
                  ]}>
                  </span>
                  <span class="sr-only">{choice.label}</span>
                </label>
              </div>
              <% {preview_bg, preview_text} = preview_colors(color_value(@event_form)) %>
              <div class="mt-2 flex items-center gap-2 text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Preview:")}
                <span class={[
                  "inline-block max-w-48 truncate rounded px-1.5 py-0.5 text-xs font-medium",
                  preview_bg,
                  preview_text
                ]}>
                  {preview_title(@event_form)}
                </span>
              </div>
            </fieldset>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.select
                field={@event_form[:status]}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}
                options={status_options()}
              />
            </div>
          </.form>
          <%!-- Participants (outside the event form — chips + search live in
               assigns, saved via replace_participants after the event) --%>
          <div class="mt-4 space-y-2">
            <p class="label-text font-semibold">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Participants")}
            </p>

            <div :if={@pending_participants != []} class="flex flex-wrap gap-1.5">
              <span
                :for={{p, idx} <- Enum.with_index(@pending_participants)}
                class="badge badge-outline gap-1 py-2.5"
              >
                <.icon name={kind_icon(p.kind)} class="w-3 h-3" />
                {p.display_name}
                <span :if={p.kind == "free_text"} class="opacity-60">
                  ({Gettext.gettext(PhoenixKitWeb.Gettext, "won't see this event")})
                </span>
                <button
                  type="button"
                  phx-click="remove_participant"
                  phx-value-idx={idx}
                  aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove participant")}
                  class="cursor-pointer hover:text-error"
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </span>
            </div>

            <%!-- Core SearchPicker (multi): the dropdown is client-rendered
                 (instant); the server only answers participant_search. Enter
                 stages the typed text — it can't submit the event form
                 because the picker lives outside it. --%>
            <.search_picker
              id="calendar-participant-search"
              dropdown_id="calendar-participant-dropdown"
              direction="up"
              class="input input-sm w-full"
              search_event="participant_search"
              results_event="calendar_participant_results"
              pick_event="add_participant"
              text_event="add_free_text_participant"
              staged_event="calendar_participant_staged"
              placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Add participants…")}
              searching_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Searching…")}
              add_prefix_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Add")}
              add_suffix_label={
                Gettext.gettext(PhoenixKitWeb.Gettext, "as text (won't see this event)")
              }
              adding_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Adding…")}
              more_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Load more")}
              loading_more_label={Gettext.gettext(PhoenixKitWeb.Gettext, "Loading…")}
            />
          </div>
        <% else %>
          <%!-- Read-only details for view_others-without-edit --%>
          <div :if={@editing_event} class="space-y-2">
            <p class="text-lg font-semibold">{@editing_event.title}</p>
            <p class="text-sm text-base-content/70">{event_when(@editing_event, @viewer_tz)}</p>
            <p :if={@editing_event.location} class="text-sm">
              <.icon name="hero-map-pin" class="w-4 h-4 inline-block" /> {@editing_event.location}
            </p>
            <p :if={@editing_event.description} class="text-sm whitespace-pre-wrap">
              {@editing_event.description}
            </p>
            <span :if={@editing_event.status == "cancelled"} class="badge badge-error badge-outline">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancelled")}
            </span>

            <div :if={@pending_participants != []} class="pt-2">
              <p class="text-xs uppercase tracking-wide text-base-content/50 mb-1">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Participants")}
              </p>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={p <- @pending_participants}
                  class="badge badge-outline gap-1"
                >
                  <.icon name={kind_icon(p.kind)} class="w-3 h-3" />
                  {p.display_name}
                </span>
              </div>
            </div>
          </div>
        <% end %>
        <% else %>
          <%!-- Skeleton while the opening click's round-trip is in flight --%>
          <div class="space-y-3 py-2" aria-busy="true">
            <div class="h-10 bg-base-content/10 rounded animate-pulse"></div>
            <div class="grid grid-cols-2 gap-3">
              <div class="h-10 bg-base-content/10 rounded animate-pulse"></div>
              <div class="h-10 bg-base-content/10 rounded animate-pulse"></div>
            </div>
            <div class="h-20 bg-base-content/10 rounded animate-pulse"></div>
            <div class="flex justify-center pt-2">
              <span class="loading loading-spinner loading-md text-base-content/40"></span>
            </div>
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

  defp event_when(%Event{all_day: true} = event, _tz) do
    last_day = Date.add(event.ends_on, -1)

    if Date.compare(event.starts_on, last_day) == :eq do
      "#{event.starts_on}"
    else
      "#{event.starts_on} – #{last_day}"
    end
  end

  defp event_when(%Event{} = event, tz) do
    starts = DateUtils.shift_to_offset(event.starts_at, tz)
    ends = DateUtils.shift_to_offset(event.ends_at, tz)
    "#{Calendar.strftime(starts, "%Y-%m-%d %H:%M")} – #{Calendar.strftime(ends, "%H:%M")}"
  end

  # Swatch choices for the color picker: value "" is the Default (no stored
  # color — the grid renders its bg-primary fallback). `text` pairs each
  # background for the live preview chip, mirroring what the grid shows.
  defp color_choices do
    [
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Blue"),
        value: "bg-primary",
        text: "text-primary-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Purple"),
        value: "bg-secondary",
        text: "text-secondary-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Teal"),
        value: "bg-accent",
        text: "text-accent-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Sky"),
        value: "bg-info",
        text: "text-info-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Green"),
        value: "bg-success",
        text: "text-success-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Yellow"),
        value: "bg-warning",
        text: "text-warning-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Red"),
        value: "bg-error",
        text: "text-error-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Gray"),
        value: "bg-neutral",
        text: "text-neutral-content"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Orange"),
        value: "bg-orange-600",
        text: "text-white"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Pink"),
        value: "bg-pink-500",
        text: "text-white"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Violet"),
        value: "bg-violet-600",
        text: "text-white"
      },
      %{
        label: Gettext.gettext(PhoenixKitWeb.Gettext, "Lime"),
        value: "bg-lime-600",
        text: "text-black"
      }
    ]
  end

  # What the preview chip (and the grid) shows for the current selection;
  # "" / nil = the grid's default rendering for a color-less event.
  defp preview_colors(value) do
    case Enum.find(color_choices(), &(&1.value == value)) do
      nil -> {"bg-primary", "text-primary-content"}
      choice -> {choice.value, choice.text}
    end
  end

  defp color_value(form), do: to_string(form[:color].value || "")

  defp preview_title(form) do
    case String.trim(to_string(form[:title].value || "")) do
      "" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Untitled event")
      title -> title
    end
  end

  defp status_options do
    [
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Confirmed"), "confirmed"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancelled"), "cancelled"}
    ]
  end
end
