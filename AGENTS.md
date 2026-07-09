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

`phoenix_kit_calendar_events` + `phoenix_kit_calendar_event_participants` — core migration **V141** (tables live in core, workspace convention; **V141 is edited IN PLACE while unreleased** — Max's rule: no new migrations for calendar schema until release; statements are idempotent-additive and already-migrated DBs roll the marker back one version and re-run). UUIDv7 PK, `owner_uuid` FK → users (`ON DELETE CASCADE` — a personal calendar follows its account). Ends are EXCLUSIVE (`[start, end)`, iCal-style, matching `phoenix_live_calendar`):

- Timed events: `starts_at`/`ends_at` (`utc_datetime`).
- All-day events: `starts_on`/`ends_on` (DATE pair — real date semantics, no UTC-midnight/DST ambiguity).
- DB CHECK `calendar_event_time_shape` enforces exactly one pair per row matching `all_day`, end > start on both; the changeset nils the inactive pair when `all_day` flips so form toggling can't trip it.
- `status`: `confirmed`/`cancelled` (CHECK-enforced). `color`: whitelisted daisyUI `bg-*` classes only (never arbitrary CSS).
- **v1 simplifications (deliberate):** no recurrence; timed events are naive wall-clock stored as UTC verbatim (no timezone conversion); no separate calendars table.

## UI

`/admin/calendar` (`Web.CalendarLive`, single-tab `live_view:` routing pattern):

- Month view via the standalone `phoenix_live_calendar` lib's `CalendarComponent` (server-rendered; the component's callbacks arrive as messages: `{:calendar_date_click, date}`, `{:calendar_event_click, id}`, `{:calendar_range_change, range}` → month navigation reloads the event window).
- Date click / "New event" → create modal; event click → edit modal (or read-only details without edit rights). All-day end date is INCLUSIVE in the form ("last day"): `shift_inclusive_end/1` (+1) at the params boundary, `inclusive_end_display/1` (−1) at render — the changeset/DB always hold the exclusive date. Toggling All day carries dates/times across (`carry_dates_from_times` / `carry_times_from_dates` in `normalize_params/1`) instead of clearing the fields.
- **The modal opens INSTANTLY** (boss's rule: users need feedback after a click): `<.modal keep_in_dom id="calendar-event-modal">` + core `PkDialogTrigger` on the grid card (event chips `.cal-event`/`.cal-multiday-bar` + `.cal-day-cell`; the "+N more" link correctly excluded) + `JS.dispatch("pk:dialog-show")` on the New event button. The body is a skeleton until the round-trip lands (`@show_event_modal`); the `get_event` error path pushes `pk:dialog-close` so a client-opened dialog can't hang empty.
- **Color** = radio-swatch grid (sr-only inputs, ring on checked) with a live preview chip mirroring the grid rendering: 8 daisyUI semantics + 4 static Tailwind hues (`@static_text_colors` pairs explicit text colors for those — the lib's `infer_text_color/1` only knows the semantic set; whitelist in `Schemas.Event`).
- **Owner row**: existing events show a labeled read-only "Calendar" field ONLY when it informs (someone else's event, or the viewer holds `edit_others`); a plain employee's own event shows nothing. Create mode without `edit_others` shows no owner UI at all (the old "On your calendar" filler was noise).
- **Layers model (quorum redesign 2026-07-09; replaced the v1 dropdown + chips)**: what you see is a SET of calendar layers — "Me" = `{me}`, one person = a set of 1, Everyone = select-all shortcut, not a mode. `view_others` holders get a toolbar **"Calendars · N" button** opening a Google-Calendar-style **checklist panel**: debounced search (name/email, in-memory over the loaded list, 50-row render cap with "N more — refine"), Me/Everyone shortcut buttons, and person rows = checkbox (membership) + deterministic **palette color dot** + name-button (click = solo) + lock icon for no-calendar-access (STILL selectable — history stays reviewable) + `empty` badge (no events in the **visible range**, via windowed `count_events_by_owner/3`). Desktop: dropdown card under the button; mobile: same markup as a dimmed overlay. Full quorum record: Codex+Vibe+Kimi unanimous on the model/pattern; URL state was Kimi's hard requirement.
- **Selection lives in the URL**: `?people=uuid1,uuid2` | `?people=all` | absent = `{me}` (shareable, back-button-safe). `sanitize_selection/2` runs on every mount/patch — unknown ids dropped, and without `view_others` the param is ignored entirely (plus the context enforces authorization on the query itself).
- **Owner color replaces title prefixes**: multi-calendar views tint events with the owner's palette color (`owner_color/1` — `phash2(uuid, 12)` into complete static Tailwind classes, purge-safe); single-calendar views keep each event's own chosen color. The modal's owner row reuses the palette dot (conditionally — see Owner row above).
- **Editing**: per-event authorization at modal-open (`can_edit_event?` vs the event's persisted owner) from ANY view. Read-only badge: single non-editable selection, or multi without `edit_others`.
- **Creating (boss's ask 2026-07-09: "New event must not go away")**: the button is ALWAYS available. The create modal carries a **target-calendar picker** for `edit_others` holders (`name="owner"` — deliberately OUTSIDE the changeset; owner is never cast, `sanitize_owner/2` clamps unknown/unauthorized values to self, and the context re-authorizes the explicit argument). Without `edit_others` the modal shows no owner UI (see Owner row above) and any crafted owner param is sanitized to self (regression-tested). Default target = the single viewed calendar when editable, else self. **If the target isn't in the current view, an inline warning says the event won't appear here** (covers both a boss picking an off-view person and a read-only viewer creating for themselves while looking at someone else).

## Cross-module integrations (2026-07-09, quorum-reviewed)

**Standalone by construction:** every integration reads the PHYSICAL sibling tables (they exist in every install via core migrations) with SCHEMALESS queries — no sibling module code is ever required; unused modules mean empty tables mean no-ops. A source is OFFERED only when its module is enabled AND the viewer holds the invite sub-permission (composes, never substitutes).

- **Location** — core `<.search_picker mode="single">` under the date fields (search-on-focus: clicking shows the stored list; falls back to a plain input when the locations module is off); exact-match text links `location_uuid` (`link_location/2`), and the context snapshots the NAME into the `location` string (rendering never needs the module; unknown uuids are dropped, free text always works).
- **Participants** — `Participants.replace_participants/3` (full-replace-with-diff, one transaction; removal revokes instantly; only NEWLY added entries notify via Activity `target_uuid` → core notifications). Kinds: `user` / `staff_person` / `crm_contact` / `crm_company` / `free_text`; per-kind gating via the three invite subs (`invite_platform_users` / `invite_staff` / `invite_crm` — quorum split; free text needs only event edit access), validated in the CONTEXT, not just the UI. `added_by_uuid` audits.
- **LIVE visibility (Max's explicit choice over save-time snapshots):** a person's schedule = events they OWN plus events they currently RESOLVE as participating in — `participant_visible_dynamic/1` is one EXISTS fragment joining `phoenix_kit_staff_people` (user_uuid link), `phoenix_kit_crm_contacts` (optional user_uuid), and company MEMBERSHIPS (company participant = whoever is a member NOW; joining a company grants visibility to existing events, leaving revokes it — regression-tested by mutating membership rows directly). Participants may open THEIR event (`Events.participant?/2` path in `get_event/2`) but never the owner's calendar. `display_name` is the only snapshot; soft-deleted (trashed) staff/contacts don't resolve.
- **Picker UI** — core `<.search_picker>` (multi mode; extracted from CRM's involved-parties picker): the dropdown is client-rendered/instant, the LV only answers `participant_search` with flattened icon+sublabel rows (min 2 chars, 8/source, name-only). Chips with kind icons; free-text rows/chips are explicitly marked "won't see this event" (people otherwise believe typing a name invites them).
- The participants test suite seeds the physical staff/CRM/locations tables schemaless with NO module code loaded — that is the standalone proof, keep it that way.

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
