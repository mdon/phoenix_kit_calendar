# AGENTS.md

Guidance for AI agents working on `phoenix_kit_calendar`.

## Overview

Personal calendars for PhoenixKit: one implicit calendar per user, with
fine-grained sub-permissions controlling access to *other* people's calendars.
This module is the reference consumer of core's sub-permission system
(`calendar.view_others` / `calendar.edit_others`) — it exists both as a real
feature and as the proving ground for that permission expansion. Events can
carry participants drawn from platform users, staff, and CRM contacts and
companies, plus a linked location; all of that is read schemalessly from the
sibling tables, so no sibling module code is required.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex), `phoenix_live_calendar` `~> 0.2` (hard; the server-rendered month component, `MiniCalendar`, and the hook bundle), `phoenix_live_view` `~> 1.1`.
- **Consumed by:** nothing calls the `Events` API. `phoenix_kit_dashboards` discovers `phoenix_kit_widgets/0` at runtime (duck-typed, one-way; no dependency in either direction).
- **Admin surface:** one tab, `:admin_calendar` at `/admin/calendar` (`Web.CalendarLive`, `live_view:` routing, group `:admin_modules`, priority 645, `match: :prefix`, permission `calendar`).
- **Module key** `"calendar"`; settings prefix `calendar_` (`calendar_enabled`).

## What this module does NOT do

- No recurrence, and no separate calendars table — events are keyed by `owner_uuid` (deliberate v1 simplifications).
- No migrations of its own: both tables ship in core's chain.
- No module-owned gettext catalogue; strings ride core's backend (see Conventions).
- Never requires sibling module code. Staff, CRM, and location integrations read the physical tables with schemaless queries; an unused module means empty tables mean no-ops. Do not add `phoenix_kit_staff` / `phoenix_kit_crm` / `phoenix_kit_locations` as deps.
- No dependency on `phoenix_kit_dashboards`; the widgets are a duck-typed contract the dashboards Registry discovers.
- Never logs an event title to the activity feed. The feed is readable by any holder of the dashboard/activity permission — broader than calendar permissions — so only uuids go in.
- No per-person participant query behind the people panel's `empty` badge: it counts events a person OWNS in the visible range, so someone with only participated events can still read `empty` (a deliberate NIT).
- Week/day views, drag-to-move/resize, and a `live_render` embed contract are not built (see TODOs).

## Commands

```bash
mix deps.get
createdb phoenix_kit_calendar_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar mix test
```

`mix test.setup` / `mix test.reset` are aliases for creating / dropping and
recreating the test database.

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- Module key `calendar`; tab id `:admin_calendar`; URL segment `calendar`. Sub-permission keys are dotted: `calendar.view_others`, `calendar.edit_others`, `calendar.invite_platform_users`, `calendar.invite_staff`, `calendar.invite_crm`.
- Paths go through `PhoenixKitCalendar.Paths` (`index/0`, `people/1`) over `PhoenixKit.Utils.Routes.path/1`; never hardcode `/admin/calendar`.
- Routing: the single tab carries `live_view: {Web.CalendarLive, :index}`; there is no `route_module/0`. Never hand-register plugin routes in a host router.
- LiveView macro: `use PhoenixKitWeb, :live_view` (`CalendarLive`, the only LiveView). It renders inside core's admin layout with `<.admin_page_header>`; no `LayoutWrapper`. The three widgets are `Phoenix.LiveComponent`s.
- Gettext: call sites use the `gettext/1` macro (extractable) on core's `PhoenixKitWeb.Gettext` backend (`use Gettext, backend: PhoenixKitWeb.Gettext` in `Participants` and the widgets; `CalendarLive` gets it from the `:live_view` macro). There are no module-owned `.po` files and core carries no calendar manifest, so these strings render untranslated until a module backend lands (TODO). Do not add a `priv/gettext` without the backend.
- JS hooks: `js_sources/0` (duck-typed, no `@impl` — core's compiler discovers it) declares `phoenix_live_calendar`'s prebuilt bundle (`static/assets/phoenix_live_calendar.js`, global `PhoenixLiveCalendarHooks`). Progressive enhancement only — the month view is fully server-rendered. Never register a hook from an inline `<script>` (morphdom does not execute inserted script tags, so it vanishes on LiveView navigation). The page also uses core's `PkDialogTrigger` and `PkDialogDraft` hooks. `css_sources/0` is `[:phoenix_kit_calendar, :phoenix_live_calendar]`.
- `enabled?/0` reads `calendar_enabled`, rescues, catches `:exit`, and returns `false`.
- Authorization lives in the context (`Events`): every function takes the caller's `Scope` and authorizes against the TARGET calendar's owner via `Scope.can?/2` (which also requires the module to be enabled — a stale scope can't act on a disabled module). The LiveView only mirrors these decisions cosmetically. Two invariants hold regardless of the calling UI:
  1. `owner_uuid` is NEVER cast from attrs — creation takes it as an explicit, separately-authorized argument; the schema doesn't cast it; an update can't move an event between calendars.
  2. Mutations are load-then-authorize: `update_event/4` and `delete_event/3` reload by uuid and the event's PERSISTED owner decides the required permission, never the caller's in-memory struct.
- Participant per-kind gating (the three invite subs) is validated in the CONTEXT (`Participants.replace_participants/3`), never only in the UI. `Participants.list_for_event/2` honours the same read boundary as `Events.get_event/2`.
- The create modal's target owner (`name="owner"`) stays OUTSIDE the changeset; `sanitize_owner/2` clamps unknown or unauthorized values to self and the context re-authorizes the explicit argument. Without `edit_others` no owner UI renders and any crafted owner param is sanitized to self.
- The layer selection lives in the URL (`?people=uuid1,uuid2` | `?people=all` | absent = `{me}`); `sanitize_selection/2` runs on every mount/patch, dropping unknown ids and ignoring the param entirely without `view_others`.
- Times: timed events are stored in UTC and shown in the VIEWER's timezone (`user_timezone` → site `"time_zone"` → `"0"`; an IANA id or a legacy fixed offset, never a number). Every conversion goes through core's per-instant helpers (`parse_datetime_local/2`, `format_datetime_local/2`, `shift_to_offset/2`). Never collapse a zone to one number and add it (`offset_to_seconds/1` is deprecated in core). All-day events are real dates; the form's end date is INCLUSIVE ("last day") and converted to the exclusive storage form at the params boundary (`shift_inclusive_end/1` / `inclusive_end_display/1`). See `dev_docs/guides/timezones.md`.
- The modal opens INSTANTLY (users need feedback after a click): `<.modal keep_in_dom>` + `PkDialogTrigger` on the grid + `JS.dispatch("pk:dialog-show")` on the New event button; the body is a skeleton until `@show_event_modal`, and the `get_event` error path pushes `pk:dialog-close` so a client-opened dialog can't hang empty.
- `color` is a whitelist of daisyUI `bg-*` semantics plus four static Tailwind hues (`Schemas.Event.colors/0`); `@static_text_colors` in the LiveView pairs explicit text colors for the static ones. Never accept arbitrary CSS classes. Owner palette classes (`owner_color/1`) are complete static strings for Tailwind purge safety.
- Activity logging: `Events.tap_log/4` on every committed mutation (`calendar_event.created` / `updated` / `deleted`, `module: "calendar"`, `mode: "manual"`), guarded with `Code.ensure_loaded?(PhoenixKit.Activity)` and rescued; `opts[:actor_uuid]` overrides the scope's user. Metadata carries only `owner_uuid` (PII rule above). Logging is isolated from the PubSub broadcast so a logging failure never suppresses the live update. `Participants` logs `calendar_event.participant_added` with `target_uuid` for newly added entries only (that is what core fans out as a notification).
- Live updates: each committed mutation broadcasts `{:calendar_event_changed, owner_uuid}` on `Events.pubsub_topic/0` via `PhoenixKit.Config.pubsub_server/0` (no-op when the host configures none). Minimal payload — owner uuid only, no record, no PII.
- Widgets query through the authorized context path with the widget's `scope` assign — a shared dashboard never leaks anyone else's events — and render defensively (nil scope/settings/size → empty state, never a crash) via `Web.WidgetSupport`, every helper of which answers in the VIEWER's frame.
- Soft-delete: none of its own; participant resolution and the search sources exclude rows with `status = 'trashed'` in the staff/CRM/locations tables.
- The `:phoenix_kit` requirement stays a two-segment `~> 2.0` (a three-segment `~> 2.0.x` excludes every later core minor and breaks `mix deps.get` for consumers); core features above the floor are feature-detected. `test/core_pin_conformance_test.exs` pins this and fails if a `path:` dep is committed.

### Landmines

- Timezone tests with numeric offsets (`"3"`) pass while every DST bug is live → tests MUST use IANA values and a window in the opposite season from "now" (or a north+south pair); see the guide.
- A new `test/support/*.ex` module is compiled but not loaded at test-helper time (Elixir 1.19 loads only `:test_load_filters` matches) → add it to the `Code.require_file/2` list in `test/test_helper.exs`, in dependency order.
- No `postgres` role on the local Postgres → `psql -lqt` finds the DB, the Repo connect fails, and every `:integration` test silently skips behind a "Could not connect" warning that reads as a pool timeout (`connection not available … dropped from queue`), not an auth error → export `PGUSER` (and `PGPASSWORD` if needed).
- Comparing two timezones by their offset "now" flips at the next DST switch with neither value changed → compare IANA ids by rule (`TimeZone.effectively_same?/2`) and anything involving a legacy offset by the fortnightly year signature (`tz_differs?/2`).
- `function_exported?/3` alone answers `false` for a core module that has merely not been loaded (the normal state under a release) → feature-detect with `Code.ensure_loaded?/1` first.

## Architecture

```
lib/phoenix_kit_calendar.ex             PhoenixKit.Module impl: module_key/0, enabled?/0, permission_metadata/0,
                                        admin_tabs/0, css_sources/0, js_sources/0, phoenix_kit_widgets/0
lib/phoenix_kit_calendar/
  events.ex                             Events context: can_view?/2, can_edit?/2, list_events/5, list_all_events/4,
                                        get_event/2, readable?/2, participant?/2, count_events_by_owner/4,
                                        create/update/delete, live location names, activity log + broadcast
  participants.ex                       list_for_event/2, replace_participants/3 (diff in one transaction)
  sources.ex                            schemaless search facade: users / staff / CRM contacts / CRM companies /
                                        locations; browse mode, per-source cap, cross-source dedup
  paths.ex                              Paths.index/0, Paths.people/1
  schemas/event.ex                      Event (time-shape validation, color/status whitelists)
  schemas/participant.ex                Participant (kind/target shape, unique constraints)
  web/calendar_live.ex                  the admin page: layers panel, event modal, tz frame, pickers
  web/widget_support.ex                 viewer-scoped, fail-soft helpers shared by the widgets
  web/upcoming_widget.ex                calendar.upcoming
  web/today_agenda_widget.ex            calendar.today
  web/mini_month_widget.ex              calendar.mini_month
```

### Permission model

| Key | Grants |
|-----|--------|
| `calendar` | The admin page + full control of YOUR OWN calendar |
| `calendar.view_others` | Read-only access to other users' calendars |
| `calendar.edit_others` | Create/edit/delete on other users' calendars (implies view) |
| `calendar.invite_platform_users` | Add platform users as participants |
| `calendar.invite_staff` | Add staff people as participants (staff module must be enabled) |
| `calendar.invite_crm` | Add CRM contacts and companies as participants (CRM module must be enabled) |

- Sub-keys are declared in `permission_metadata/0` (`sub_permissions:`) and stored as dotted keys in core's `phoenix_kit_role_permissions`. Core enforces sub-implies-base (granting a sub auto-grants `calendar`; revoking `calendar` cascades the subs off).
- Role recipes: **Employee** = `calendar`; **Junior Manager** = + `view_others`; **Boss** = + `edit_others`. Admin/Owner hold everything by default (Owner always; Admin via auto-grant, Owner-revocable).
- Page access needs the base key (core's admin `on_mount` chain). Everything finer is decided per event by the context.

### Data model

Tables (core's chain), UUIDv7 PKs, `use PhoenixKit.SchemaPrefix` on both schemas:

- `phoenix_kit_calendar_events` — `owner_uuid` FK → users (`ON DELETE CASCADE`: a personal calendar follows its account), `title`, `description`, `location` (name snapshot), `location_uuid`, `all_day`, `starts_at`/`ends_at` (`utc_datetime`, timed), `starts_on`/`ends_on` (`date`, all-day), `color`, `status` (`active`/`cancelled`). Ends are EXCLUSIVE (`[start, end)`, iCal-style, matching `phoenix_live_calendar`). CHECK `calendar_event_time_shape` enforces exactly one pair per row matching `all_day` with end > start; the changeset nils the inactive pair when `all_day` flips so form toggling can't trip it. CHECK `calendar_event_status`. Indexes on `(owner_uuid, starts_at)` and `(owner_uuid, starts_on)`.
- `phoenix_kit_calendar_event_participants` — `event_uuid` FK → events (CASCADE), `kind` (`user` / `staff_person` / `crm_contact` / `crm_company` / `free_text`), `target_uuid` (NULL only for `free_text`), `display_name` (the only snapshot), `added_by_uuid`. CHECKs `calendar_participant_kind`, `calendar_participant_shape`; unique `idx_calendar_participants_target` (event, kind, target) and `idx_calendar_participants_free_text` (event, `LOWER(display_name)`).
- A person's schedule = events they OWN plus events they currently RESOLVE as participating in (one EXISTS fragment over the physical staff/CRM/membership tables). See `dev_docs/guides/participants.md`.

### Runtime contracts

| Contract | Shape |
|----------|-------|
| PubSub topic | `Events.pubsub_topic/0` = `"phoenix_kit_calendar:events"`, payload `{:calendar_event_changed, owner_uuid}` |
| Calendar component messages | `{:calendar_date_click, date}`, `{:calendar_event_click, id}`, `{:calendar_range_change, %{start:, end:}}` |
| Setting | `calendar_enabled` (boolean) |
| Activity actions | `calendar_event.created` / `.updated` / `.deleted` / `.participant_added`; `resource_type: "calendar_event"` |
| URL state | `?people=uuid,uuid` or `?people=all`; absent = own calendar |
| Widgets (`phoenix_kit_widgets/0`) | `calendar.upcoming` (`limit`, `show_location`; 60-day horizon), `calendar.today` (`show_location`; all-day first then by time), `calendar.mini_month` (a dot on each day with events); all `module_key: "calendar"`, sizes in the dashboards lattice |

## Database & migrations

None. Tables `phoenix_kit_calendar_events` and
`phoenix_kit_calendar_event_participants` ship in core's chain (core V141,
above the V135 baseline); `migration_module/0` is unset. That migration is
released and immutable: a schema change is a new core migration first, then
schema edits here. UUIDv7 PKs; `use PhoenixKit.SchemaPrefix` on both
table-backed schemas (`test/schema_prefix_conformance_test.exs` enforces it).

## Testing

- Test DB `phoenix_kit_calendar_test` (`MIX_TEST_PARTITION` suffix honoured); `PGUSER` / `PGPASSWORD` / `PGHOST` honoured, defaulting to `postgres` / `postgres` / `localhost`.
- Without Postgres: the behaviour test, the two conformance tests, and the changeset tests run; everything on `DataCase` / `LiveCase` is `@moduletag :integration` and is excluded. `test_helper.exs` probes for the DB with `psql -lqt`, then connects; either failure prints a warning and excludes `:integration`.
- Schema: `PhoenixKit.Migration.ensure_current(PhoenixKitCalendar.Test.Repo, log: false)` builds core's full chain (which includes the calendar tables); there is no module chain. `test_helper.exs` also starts `PhoenixKit.PubSub.Manager`, `PhoenixKit.ModuleRegistry`, and `PhoenixKit.Users.RateLimiter.Backend` (`Auth.register_user/2` hits it), forces core's URL prefix to `/`, and starts the test Endpoint only when the DB is available.
- Support modules (`test/support/`): `DataCase` (sandbox owner, `errors_on/1`), `LiveCase` (`fake_scope/1`, `put_test_scope/2`, imports `Phoenix.LiveViewTest`), `Test.Endpoint` (`server: false`), `Test.Router` (`/en/admin/calendar` in a `live_session` with `Test.Hooks` `:assign_scope`, which mirrors the session's `"phoenix_kit_test_scope"` onto `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`), `Test.Layouts`, `Test.Repo`, `ActivityLogAssertions` (`assert_activity_logged/2`, imported into both cases).
- `fake_scope/1` builds a real `%Scope{}` with a real `%User{}`, a precise `cached_permissions` MapSet, and an optional `user_timezone`. Events tests still create REAL users (`Auth.register_user/2`) because `owner_uuid` is a genuine FK.
- The participants suite seeds the physical staff/CRM/locations tables schemaless with `Repo.insert_all/2` and NO module code loaded — that is the standalone proof; keep it that way.
- The widget suite pins that a shared dashboard never leaks another viewer's events.
- Timezone tests use IANA zones across both hemispheres and windows in the opposite season (Landmines).
- Known noise: `mix test` prints "redefining module PhoenixKitCalendar.Test.*" warnings — `test_helper.exs` `Code.require_file`s the support modules that `elixirc_paths(:test)` already compiled. Harmless.

## Feature notes

| Feature | Constraint that must hold | Guide |
|---------|---------------------------|-------|
| Timezones | Storage is UTC; every conversion is per-instant through core's helpers in the viewer's frame; the modal's input frame converts with the frame the values were DISPLAYED in before recomputing it; zone identity is compared by rule or year signature, never by today's offset. | `dev_docs/guides/timezones.md` |
| Calendar layers and the event modal | The visible set is URL state sanitized on every mount/patch; the modal opens client-side instantly and authorizes per event against the persisted owner; the owner picker is outside the changeset and clamped to self; a reconnect restores the draft only after re-fetching and re-authorizing. | `dev_docs/guides/calendar-layers.md` |
| Participants and locations | Sibling tables are read schemalessly, never through sibling code; visibility resolves LIVE (company = current members); per-kind invite gating is enforced in the context; only newly added entries notify; the location name is snapshotted at save and re-resolved live at read. | `dev_docs/guides/participants.md` |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- Week/day views (the lib supports them; month is the polished one).
- Recurrence.
- `live_render` embed contract (the LV body is componentizable; the widgets cover dashboards today).
- Dedicated module gettext backend for domain strings (call sites already use the `gettext/1` macro; they still ride core's backend, untranslated, until a module backend lands).
- Drag-to-move/resize via the lib's hooks (`enable_hooks` + `on_event_drop`/`on_event_resize`).
- Once the core floor reaches the release with `TimeZone.for_viewer/1`, `date_start/2` and `local_date/2`: collapse the private `viewer_timezone/2`, `WidgetSupport.viewer_tz/1` / `local_today/1` and `Events.local_midnight/2` into those.
- A permission-scoped activity feed would be the right home for event titles; until core offers one, titles stay out of the global feed.
