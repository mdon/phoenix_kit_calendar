# AGENTS.md

**PhoenixKitCalendar** — personal calendars for PhoenixKit. One implicit calendar per user; fine-grained sub-permissions control access to *other* people's calendars. This module is the reference consumer of core's sub-permission system (`calendar.view_others` / `calendar.edit_others`) — it exists both as a real feature and as the proving ground for that permission expansion.

## Permission model (the point of this module)

| Key | Grants |
|-----|--------|
| `calendar` | The admin page + full control of YOUR OWN calendar |
| `calendar.view_others` | Read-only access to other users' calendars |
| `calendar.edit_others` | Create/edit/delete on other users' calendars |

- Sub-keys are declared in `permission_metadata/0` (`sub_permissions:`) and stored as dotted keys in core's `phoenix_kit_role_permissions`. Core enforces sub-implies-base (granting a sub auto-grants `calendar`; revoking `calendar` cascades the subs off).
- Role recipes: **Employee** = `calendar`; **Junior Manager** = + `view_others`; **Boss** = + `edit_others`. Admin/Owner hold everything by default (Owner always; Admin via auto-grant, Owner-revocable).
- **Authorization lives in the context** (`PhoenixKitCalendar.Events`): every function takes the caller's `Scope` and authorizes against the TARGET calendar's owner via `Scope.can?/2` (which also requires the module to be enabled — stale scopes can't act on a disabled module). The LiveView only mirrors these decisions cosmetically.
- Two invariants, enforced regardless of the calling UI:
  1. `owner_uuid` is NEVER cast from attrs — creation takes it as an explicit, separately-authorized argument; the schema doesn't cast it; an update can't move an event between calendars.
  2. Mutations are load-then-authorize: the event's PERSISTED owner decides the required permission.

## Data model

`phoenix_kit_calendar_events` — core migration **V141** (tables live in core, workspace convention). UUIDv7 PK, `owner_uuid` FK → users (`ON DELETE CASCADE` — a personal calendar follows its account). Ends are EXCLUSIVE (`[start, end)`, iCal-style, matching `phoenix_live_calendar`):

- Timed events: `starts_at`/`ends_at` (`utc_datetime`).
- All-day events: `starts_on`/`ends_on` (DATE pair — real date semantics, no UTC-midnight/DST ambiguity).
- DB CHECK `calendar_event_time_shape` enforces exactly one pair per row matching `all_day`, end > start on both; the changeset nils the inactive pair when `all_day` flips so form toggling can't trip it.
- `status`: `confirmed`/`cancelled` (CHECK-enforced). `color`: whitelisted daisyUI `bg-*` classes only (never arbitrary CSS).
- **v1 simplifications (deliberate):** no recurrence; timed events are naive wall-clock stored as UTC verbatim (no timezone conversion); no separate calendars table.

## UI

`/admin/calendar` (`Web.CalendarLive`, single-tab `live_view:` routing pattern):

- Month view via the standalone `phoenix_live_calendar` lib's `CalendarComponent` (server-rendered; the component's callbacks arrive as messages: `{:calendar_date_click, date}`, `{:calendar_event_click, id}`, `{:calendar_range_change, range}` → month navigation reloads the event window).
- Date click / "New event" → create modal; event click → edit modal (or read-only details without edit rights). All-day end date is INCLUSIVE in the form ("last day") and shifted ±1 day at the LV boundary (`normalize_params/1` / `inclusive_end/1`).
- **Person switcher** (only for `view_others` holders): lists ALL active users — deliberately including people without calendar access, so an admin can review the calendar of someone whose permissions were revoked (boss's explicit call, 2026-07-08) — annotated with `(no calendar access)` / `(empty)`. `?user=<uuid>` param; unauthorized/unknown values silently fall back to the own calendar.
- Read-only badge when viewing without `edit_others`.

## Dashboard widget

`calendar.upcoming` (`Web.UpcomingWidget`) via the duck-typed `phoenix_kit_widgets/0` contract — the viewer's next events, queried through the authorized context path with the widget's `scope` assign (a shared dashboard never leaks anyone else's events). Renders defensively; never crashes the host.

## Wiring

- `css_sources: [:phoenix_kit_calendar, :phoenix_live_calendar]`; duck-typed `js_sources/0` declares the calendar lib's hook bundle (progressive enhancement only — month view is fully server-rendered).
- Activity logging on every mutation (`calendar_event.created/updated/deleted`, guarded + rescued).
- Deps via `pk_dep/3`: `PHOENIX_KIT_PATH=../phoenix_kit PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar mix test` for local-dep runs.

## Cross-repo gate

The module needs core **> 1.7.179** (sub-permissions + `Scope.can?/2` + V140/V141). Until Max cuts that release and the pin floats onto it, the standalone suite is **red against the published pin** — always run with `PHOENIX_KIT_PATH=../phoenix_kit`. This is the documented workspace pattern, not CI (no GitHub Actions here).

## Development

```bash
mix test.setup                                    # createdb phoenix_kit_calendar_test
PHOENIX_KIT_PATH=../phoenix_kit PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar mix test
mix format && mix credo --strict
```

Test infra is the hello_world pattern (test Endpoint/Router/Layouts/LiveCase under `test/support/`; schema via `PhoenixKit.Migration.ensure_current/2`). `fake_scope/1` builds a real `%Scope{}` with a real `%User{}` and a precise `cached_permissions` MapSet — but events tests still create REAL users (`Auth.register_user/2`) because `owner_uuid` is a genuine FK. The test_helper also starts `RateLimiter.Backend` (register_user hits it).

## Commit rules

Start with action verbs (`Add`, `Update`, `Fix`, `Remove`). **No AI attribution.** Releases/version bumps are Max-only — PRs land at the current version. Tags are bare version numbers (no `v` prefix).

## TODO (post-v1)

- Week/day views (the lib supports them; month is the polished one).
- Recurrence.
- Real timezone handling for timed events.
- `live_render` embed contract (the LV body is componentizable; the widget covers dashboards today).
- Hybrid gettext (strings currently ride core's backend; domain strings should move to a module backend when i18n lands).
- Drag-to-move/resize via the lib's hooks (`enable_hooks` + `on_event_drop`/`on_event_resize`).
