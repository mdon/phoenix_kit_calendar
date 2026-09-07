## 0.2.2 - 2026-09-07

### Fixed

- **Timezones now resolve at each question's own instant, not today's.** Since
  core 2.13.9 a stored timezone is an IANA id (`Europe/Warsaw`), not a number,
  and this module was still turning it into one offset and adding that. Every
  conversion goes through core's per-instant helpers instead, so a named zone
  follows daylight saving on the date being shown:

  - The day window (`Events.list_events/5`, `list_all_events/4`,
    `count_events_by_owner/4`) resolved both bounds with the zone's offset
    *today*. A Tallinn viewer opening January from September got both bounds an
    hour early — the last local hour of January 31 fell out of the month and
    the last hour of December 31 leaked in. Each bound is now read at its own
    date.
  - The calendar page took `today` from UTC. Between local and UTC midnight
    (00:00–03:00 in Tallinn in summer) the grid highlighted yesterday, "New
    event" prefilled yesterday, and on the first of a month the page opened on
    the previous month.
  - The cross-timezone indicator compared offsets, which could not read an IANA
    id at all: `Europe/Warsaw` and `America/New_York` compared equal, so the
    "Use their timezone" checkbox never appeared. Two ids are now compared by
    their daylight-saving rule, and anything involving a legacy offset by a
    year-round signature — so the answer can't flip at the next switch with
    neither value changed.
  - That indicator's labels were a numeric parse of the value and read "Alice
    is in UTC — you are in UTC" for any two named zones. They are core's own
    labels now.

- **The dashboard widgets order events in the viewer's timezone.** The sort key
  compared an all-day event's local start DATE against a timed event's UTC
  instant. For any viewer east of UTC an early-morning event outranked the same
  day's all-day events — 02:00 in Tallinn is 23:00Z the day before — so Today
  listed it above the all-day rows it leads with, and Upcoming placed it under
  the previous day. `WidgetSupport.sort_key/2` now takes the viewer's timezone;
  the sets of events shown were never affected, only their order.

- Replaced daisyUI 4 classes on the event modal that style nothing in v5.

### Changed

- Dependency updates, most notably `phoenix_kit` 2.2.0 → 2.15.1 (which brings
  the IANA timezone database via `tz`), plus `phoenix` 1.8.13,
  `phoenix_live_view` 1.2.11, `oban` 2.24.1, `ecto` 3.14.2 and the transitive
  set around them.

  The `:phoenix_kit` requirement stays `~> 2.0`. The timezone work is
  feature-detected, so this release still resolves and runs against a core
  below 2.13.9 — it simply has no IANA identifiers to tell apart there.

## 0.2.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.2.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

## 0.1.0 - 2026-07-11

Initial release. Personal calendars for PhoenixKit — one implicit calendar per
user, with fine-grained sub-permissions (`calendar.view_others` /
`calendar.edit_others`) controlling access to *other* people's calendars.

### Added
- **`Web.CalendarLive`** (`/admin/calendar`) — month view via
  `phoenix_live_calendar`'s `CalendarComponent`, create/edit/delete modals,
  a "Calendars" panel for switching or overlaying other users' calendars
  (permission-gated), and live cross-tab updates via a scoped PubSub topic.
- **`Events` context** — the authorization boundary for all calendar reads
  and mutations. Every function authorizes against the target calendar's
  owner via `Scope.can?/2`; mutations are load-then-authorize against the
  persisted owner, and `owner_uuid` is never cast from user-supplied attrs.
- **Timed and all-day events** (`starts_at`/`ends_at` vs `starts_on`/`ends_on`,
  exclusive end, iCal-style), stored in true UTC and displayed/entered in the
  viewer's offset-hours timezone, with a cross-timezone indicator + explicit
  "Use their timezone" entry mode when editing another owner's calendar.
- **Participants** — invite platform users, staff, or CRM contacts to an
  event via a cross-source search picker with load-more pagination,
  cross-source de-duplication (linked user > staff > CRM contact), and
  source-level invite permission gating.
- **Three dashboard widgets** (`calendar.upcoming`, `calendar.today`,
  `calendar.mini_month`) via the duck-typed `phoenix_kit_widgets/0` contract,
  each scoped strictly to the viewer's own calendar and rendering
  defensively (nil scope/settings/size never crashes the host dashboard).
- Activity logging on every mutation (`calendar_event.created/updated/deleted`).

### Fixed
- Dashboard widgets (`Upcoming`, `Today`) sorted events by default term
  order on a `DateTime` struct instead of chronologically, which silently
  broke "soonest first" / "all-day first" whenever the event set crossed a
  month boundary. Both now sort with an explicit `DateTime` comparator.
- `CalendarLive.mount/3` ran an ungated database query for the people panel
  that never refreshed for the life of the socket (a stale roster after
  mount) and duplicated on the disconnected+connected mount pair. The load
  now happens in `handle_params/3`, in line with the rest of the LiveView's
  fresh-scope-on-every-navigation convention.
- `Events.tap_log/4` ran activity logging and the PubSub live-update
  broadcast in the same rescue block, so a logging failure could silently
  suppress the broadcast too. The two are now isolated from each other.
