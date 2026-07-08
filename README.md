# PhoenixKitCalendar

Personal calendars for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — every user gets their own calendar, and fine-grained permissions decide who may see or edit anyone else's.

## Features

- **Personal calendar per user** — month view at `/admin/calendar`, server-rendered via [`phoenix_live_calendar`](https://hex.pm/packages/phoenix_live_calendar) (works without JavaScript).
- **Fine-grained permissions** — the module declares sub-permissions under its base key:
  - `calendar` — access the page, manage your own calendar
  - `calendar.view_others` — read-only access to other users' calendars
  - `calendar.edit_others` — full write access to other users' calendars
- **Person switcher** — holders of `view_others` can open any active user's calendar (including users whose access was revoked — their history stays reviewable), annotated with access/empty state.
- **Timed and all-day events** — exclusive-end semantics (iCal-style), status (confirmed/cancelled), color, location, description.
- **Dashboard widget** — "Upcoming events" for [`phoenix_kit_dashboards`](https://github.com/BeamLabEU/phoenix_kit_dashboards), scoped to the viewer.
- **Activity logging** on every mutation.

## Role recipes

Create roles in `/admin/users/roles`, grant keys in `/admin/users/permissions`:

| Role | Keys | Result |
|------|------|--------|
| Employee | `calendar` | Own calendar only |
| Junior Manager | `calendar`, `calendar.view_others` | Sees everyone's, edits own |
| Boss | `calendar`, `calendar.view_others`, `calendar.edit_others` | Sees and edits everyone's |

Owner always has everything; Admin defaults to everything (Owner-revocable).

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_calendar, "~> 0.1"}
  ]
end
```

Then `mix deps.get` and run `mix phoenix_kit.update` in the host app (the events table ships as PhoenixKit core migration V141). Enable the module on `/admin/modules`.

Requires `phoenix_kit` with sub-permission support (> 1.7.179).

## Development

```bash
mix test.setup     # create the test database
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

## License

MIT
