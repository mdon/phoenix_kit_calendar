# Review: PR #6 — Resolve every timezone question at its own instant, not today's

Reviewed against `AGENTS.md`'s (rewritten) timezone paragraph and the `Time semantics`
moduledoc of `Web.CalendarLive`. Scope: `lib/phoenix_kit_calendar/events.ex`,
`lib/phoenix_kit_calendar/web/calendar_live.ex`,
`lib/phoenix_kit_calendar/web/widget_support.ex` and the two test files, as merged at
`5747c9e` (squash of PR #6, author Max Don), current tree at `6ca87d0`.

Methodology: read every changed function with full surrounding context, then read the
CORE side of every helper the PR now leans on — `PhoenixKit.Utils.Date`
(`parse_datetime_local/2`, `shift_to_offset/2`, `offset_to_seconds/1`),
`PhoenixKit.Utils.TimeZone` (`identifier?/1`, `effectively_same?/2`, `same_group?/2`,
`from_wall/2`, `shift/2`, `label/1`) and `PhoenixKit.Settings.get_timezone_label/1` —
rather than taking the commit message's claims about them at face value. Two of those
claims were checked by running against the compiled tz database, and the availability
claims were checked against core's own git history. The PR's diff itself is correct;
the one finding is a place the sweep did not reach.

## Findings

### BUG-MEDIUM — the widgets' sort key still mixes an instant with a local date

`lib/phoenix_kit_calendar/web/widget_support.ex`

```elixir
def sort_key(%Event{all_day: true} = event),
  do: DateTime.new!(event.starts_on, ~T[00:00:00], "Etc/UTC")

def sort_key(%Event{} = event), do: event.starts_at
```

This is the same mistake the PR swept for, one module over. `starts_on` is a **local
calendar date** — the whole point of the all-day DATE pair — and it is read here at
00:00 as if it were a UTC instant. `starts_at` is a **true UTC instant**. The two keys
are then compared against each other by `Enum.sort_by(..., DateTime)` in both widgets
that use them.

Everything else in `WidgetSupport` had already been moved into the viewer's frame —
`local_today/1`, `occupied_dates/2`, `on_date?/3` — so the sort key was the last
UTC-framed value in the file, and the module's own docstring promises an ordering it
cannot deliver.

A timed event sorts ahead of an all-day event on the same local day whenever its local
start time is earlier than the viewer's UTC offset. Concretely, for a Tallinn viewer
(UTC+3 in summer):

- `TodayAgendaWidget` — a 02:00 standup is stored `23:00Z the previous day`, so it
  sorts **before** `today 00:00Z` and leads the agenda, above the all-day rows the
  widget's moduledoc says come first ("all-day events first, then timed events in
  chronological order").
- `UpcomingWidget` — tomorrow's 02:00 event is stored `today 23:00Z`, landing
  **between** today's all-day row (`today 00:00Z`) and tomorrow's (`tomorrow 00:00Z`).
  In a list whose only job is "soonest first", it reads as belonging to the wrong day.

Reachable for every viewer east of UTC with an early-morning event — most of Europe and
Asia — and symmetrically for negative offsets with late-evening ones. Cosmetic only:
the ordering is wrong, the SET of events is not (`fetch_events/3` and `on_date?/3` were
already frame-correct), so nothing is disclosed or hidden.

**Fixed** by giving both kinds the same frame — the viewer's wall clock, labelled UTC so
the two remain comparable:

```elixir
@spec sort_key(Event.t(), String.t()) :: DateTime.t()
def sort_key(%Event{all_day: true} = event, _tz),
  do: DateTime.new!(event.starts_on, ~T[00:00:00], "Etc/UTC")

def sort_key(%Event{} = event, tz) do
  event.starts_at
  |> PhoenixKit.Utils.Date.shift_to_offset(tz)
  |> DateTime.to_naive()
  |> DateTime.from_naive!("Etc/UTC")
end
```

`shift_to_offset/2` rather than a fixed offset, for the same reason the rest of the PR
uses the per-instant helpers: the shift has to be the one in force on the event's own
date. Both call sites (`TodayAgendaWidget.todays_events/3`,
`UpcomingWidget.upcoming_events/2`) already had the viewer's tz on hand. The arity
change is safe — `WidgetSupport` is an internal helper for this module's three widgets,
with no callers outside the repo.

Two regression tests added to `widget_test.exs`'s "chronological ordering" block, both
pinned to `Europe/Tallinn` (positive in either season, so the suite catches this
year-round) and both confirmed to fail against the old key and pass against the new one:

- *Today leads with the all-day rows for a viewer east of UTC* — a 02:00 local standup
  must not outrank the day's all-day event.
- *Upcoming keeps an early-morning event under its own day* — tomorrow 02:00 must sort
  after tomorrow's all-day row, not between the two days.

Test helpers `scope_in/2`, `all_day_on/3` and `timed_local/5` were added alongside; the
last builds its instant through `parse_datetime_local/2`, so the stored value is the one
a person in that zone would actually have typed rather than a hand-copied offset.

### NITPICK — `load_people/1` is the one tz fallback that doesn't guard the empty string

`lib/phoenix_kit_calendar/web/calendar_live.ex:769`

```elixir
tz: u.user_timezone || site_tz
```

Every other fallback in the file guards emptiness as well as nil — `viewer_timezone/2`
matches `is_binary(tz) and tz != ""`, and `owner_timezone/2`'s direct-lookup branch does
the same. Here `||` catches only `nil`, so a stored `""` would become the owner's
"effective zone", and the modal would then disagree with itself: `tz_differs?/2`
normalizes `""` to the site default (via `normalize_tz/1`) while `input_tz` /
`modal_owner_tz` keep the raw `""`, which core reads as UTC. The banner would name one
zone and the entry frame would be another.

**Not fixed** — not reachable through supported writes. Core's `validate_user_timezone/1`
(`phoenix_kit/lib/phoenix_kit/users/auth/user.ex:903`) converts `""` (and any
whitespace-only value) to `nil` before storage on every changeset that casts the field,
so only direct SQL can produce the row. Recorded rather than patched: the three
fallbacks disagreeing is worth knowing about, but a guard here would be dead code
defending against a state core does not allow.

## Verified, no change needed

Each of these is a claim the PR makes that could have been wrong; all four hold.

- **Both unguarded core calls really do predate the `~> 2.0` floor.** The commit message
  asserts this, and the module's `core_pin_conformance_test.exs` exists because getting
  it wrong is an `UndefinedFunctionError` for any host on an older core. Checked against
  core's history: `Settings.get_timezone_label/1` landed in **v1.7.206** (`89d811fd`,
  "Add a cheap timezone-label accessor that never queries roles") and
  `Utils.Date.parse_datetime_local/2` in **v1.7.97** (`868a9b8d`). Only `TimeZone`
  (2.13.9) needs the feature detection it has. `get_timezone_label/1` is also the cheap
  arity — it resolves through `TimeZone.label/1` and never builds the settings-options
  map, so no role query is added to the modal's render path.
- **The identifier path cannot reproduce the "Alice is in UTC — you are in UTC" shape it
  replaces.** `effectively_same?/2` delegates two identifiers to `same_group?/2`, which
  returns `false` when either zone has no group — a zone would then differ from
  *itself*. Ran the check against the compiled tz database: all **447** of core's
  `identifiers/0` resolve to a group, none orphaned, so `same_zone?/2`'s identifier
  branch is total over every value `identifier?/1` admits.
- **`year_signature/1`'s cost is not a problem in the render path.** It is 24
  `parse_datetime_local/2` calls per zone, recomputed on every `validate` event via
  `assign_tz_frame/2`, which looks alarming. Measured: **0.30 ms** for a full mixed-pair
  `tz_differs?/2` (both signatures, 48 conversions). No memoization warranted.
- **The IANA change to `shift_to_offset/2` is inert for the grid.** Since core routed it
  through `TimeZone.shift/2`, an IANA id yields a genuinely zoned `DateTime` (its
  `time_zone` names the zone) where a legacy offset still yields a UTC-labelled fake.
  `to_lib_event/3` feeds those to `PhoenixLiveCalendar.Event`, so the difference matters
  only if the lib compares instants. It doesn't for placement — `first_date/1`,
  `last_date/1`, `occurs_on?/2` all go through its private `to_date/1`, i.e. the wall
  clock — and where it does use `DateTime.compare/2` (sorting), every event has been
  shifted by the same zone, so the relative order is identical either way.

Also spot-checked and correct as written: `local_midnight/2`'s fallback matches the `0`
that `offset_to_seconds/1` used to answer for an unusable value (and the PR pins it);
noon is the right sample instant for `year_signature/1`, since DST transitions happen
between 00:00 and 03:00 and can never make it ambiguous or skipped; `Keyword.get(opts,
:viewer_tz, "0")` still behaves for an explicit `nil` because `from_wall/2` reads `nil`
as UTC; and `UpcomingWidget.past?/3` correctly compares timed events as instants while
comparing all-day ones as local dates.

## Validation gate

`mix precommit` — `compile --force --warnings-as-errors`, `deps.unlock --check-unused`,
`hex.audit`, then `quality.ci` (`format --check-formatted`, `credo --strict`,
`dialyzer`). Plus `mix test` (125 tests) against a real Postgres. Results in the
commit that carries this review.

Run against the **published** `phoenix_kit` pin (2.15.1 from Hex), not the local
checkout: `AGENTS.md`'s cross-repo-gate note dates from when the calendar's V141/V142
migrations were still unreleased, and core has long since shipped past them — the
standalone suite is green on the published pin now. That note is stale and could be
dropped the next time `AGENTS.md` is touched.
