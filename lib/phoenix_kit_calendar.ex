defmodule PhoenixKitCalendar do
  @moduledoc """
  Personal calendars for PhoenixKit — one implicit calendar per user, with
  fine-grained permissions over *other* people's calendars.

  ## Permission model

  This module is the reference consumer of PhoenixKit's fine-grained
  sub-permissions:

  | Key | Grants |
  |-----|--------|
  | `calendar` | The calendar admin page + full control of YOUR OWN calendar |
  | `calendar.view_others` | Read-only access to other users' calendars |
  | `calendar.edit_others` | Create/edit/delete events on other users' calendars |

  Typical role setup (created in `/admin/users/roles`, granted in the
  permissions matrix):

  - **Employee** — `calendar` (own calendar only)
  - **Junior Manager** — `calendar` + `calendar.view_others`
  - **Boss** — `calendar` + `calendar.view_others` + `calendar.edit_others`

  Admin and Owner hold every key by default (Owner always; Admin via
  seeding/auto-grant, revocable by the Owner in the matrix).

  Authorization happens at the context layer (`PhoenixKitCalendar.Events`) —
  every function takes the caller's scope and checks it against the event's
  owner, so the rules hold no matter which UI drives it.

  ## Data model

  `phoenix_kit_calendar_events` (core migration V141): events keyed by
  `owner_uuid` (CASCADE on user delete). Timed events store an
  exclusive-end UTC pair; all-day events store an exclusive-end DATE pair
  (`[start, end)`, iCal-style — matching `phoenix_live_calendar`).
  Recurrence is deliberately out of scope for v1.

  ## UI

  `/admin/calendar` renders the month view via the standalone
  `phoenix_live_calendar` library (server-rendered; JS hooks are optional
  progressive enhancement). Users holding `calendar.view_others` get a
  person switcher listing all active users — including people who no
  longer hold calendar access, so an admin can always review old events —
  annotated with whether each user has events and whether they currently
  hold calendar access.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @doc "Unique key for this module. Used in settings, permissions, and PubSub events."
  def module_key, do: "calendar"

  @impl PhoenixKit.Module
  @doc "Display name shown in the admin UI."
  def module_name, do: "Calendar"

  @impl PhoenixKit.Module
  @doc """
  Whether the module is currently enabled.

  Reads from the DB-backed settings table; defensive against DB
  unavailability around startup (all failure branches return `false`).
  """
  def enabled? do
    Settings.get_boolean_setting("calendar_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  @doc "Enables the module by persisting a boolean setting."
  def enable_system do
    Settings.update_boolean_setting_with_module("calendar_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  @doc "Disables the module. Same pattern as `enable_system/0`."
  def disable_system do
    Settings.update_boolean_setting_with_module("calendar_enabled", false, module_key())
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @doc "Version string. Shown on the admin Modules page. Reads the app spec so it can't drift from mix.exs."
  def version do
    case Application.spec(:phoenix_kit_calendar, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @impl PhoenixKit.Module
  @doc """
  Permission metadata for the roles/permissions matrix.

  Declares the base `calendar` key plus the two fine-grained
  sub-permissions gating access to OTHER users' calendars. Sub-keys are
  stored as `"calendar.view_others"` / `"calendar.edit_others"` and
  checked in the Events context via `PhoenixKit.Users.Auth.Scope.can?/2`.
  """
  def permission_metadata do
    %{
      key: module_key(),
      label: "Calendar",
      icon: "hero-calendar-days",
      description: "Personal calendars — own calendar per user",
      sub_permissions: [
        %{
          key: "view_others",
          label: "View others' calendars",
          description: "Read-only access to other users' calendars"
        },
        %{
          key: "edit_others",
          label: "Edit others' calendars",
          description: "Create, edit, and delete events on other users' calendars"
        }
      ]
    }
  end

  @impl PhoenixKit.Module
  @doc "Admin sidebar tab. The route is auto-generated from `live_view`."
  def admin_tabs do
    [
      %Tab{
        id: :admin_calendar,
        label: "Calendar",
        icon: "hero-calendar-days",
        path: "calendar",
        priority: 645,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        live_view: {PhoenixKitCalendar.Web.CalendarLive, :index}
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc "OTP apps whose templates Tailwind should scan for CSS classes."
  def css_sources, do: [:phoenix_kit_calendar, :phoenix_live_calendar]

  # The month view renders without JS (Phoenix-first); the calendar lib's
  # hooks are progressive enhancement (marker ticker / popover pause /
  # drag interactions), wired automatically into the host's LiveSocket by
  # core's :phoenix_kit_js_sources compiler.
  #
  # NOTE: no `@impl PhoenixKit.Module` — the core behaviour doesn't declare a
  # `js_sources/0` callback; core's compiler discovers it duck-typed.
  @doc false
  def js_sources do
    [
      %{
        app: :phoenix_live_calendar,
        file: "static/assets/phoenix_live_calendar.js",
        global: "PhoenixLiveCalendarHooks"
      }
    ]
  end

  # ── Dashboard widgets ──────────────────────────────────────────────────────
  #
  # Duck-typed, one-way contract with phoenix_kit_dashboards: no dependency on
  # the dashboards package; its Registry discovers this function at runtime.
  @doc false
  def phoenix_kit_widgets do
    [
      %{
        key: "calendar.upcoming",
        name: "Upcoming events",
        description: "Your next calendar events, soonest first.",
        icon: "hero-calendar-days",
        # Offered only when this module is enabled + permitted for the viewer.
        module_key: module_key(),
        component: PhoenixKitCalendar.Web.UpcomingWidget,
        category: "Calendar",
        default_size: %{w: 3, h: 2},
        min_size: %{w: 2, h: 1},
        max_size: %{w: 6, h: 4},
        refresh_interval: 60_000,
        settings_schema: [
          %{key: "limit", type: :number, label: "Events to show", default: "5"},
          %{key: "show_location", type: :boolean, label: "Show location", default: true}
        ]
      }
    ]
  end
end
