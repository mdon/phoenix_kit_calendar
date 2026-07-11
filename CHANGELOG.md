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
