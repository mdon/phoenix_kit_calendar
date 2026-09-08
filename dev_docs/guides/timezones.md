# Timezones

How timed events move between UTC storage and the wall clocks people see and type.
Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions and Feature notes.

## Storage and the viewer's frame

Timed events are stored in true UTC and displayed/entered in the VIEWER's
timezone — `user_timezone` → site `"time_zone"` setting → `"0"`. That value is
an **IANA id** (`Europe/Warsaw`) on any account or site that touched the
picker, or a legacy fixed offset (`"2"`) on rows written before core knew ids;
never a number. All-day events use real dates (`starts_on`/`ends_on`) and
have no timezone at all.

Every conversion goes through core's per-instant helpers
(`PhoenixKit.Utils.Date.parse_datetime_local/2`, `format_datetime_local/2`,
`shift_to_offset/2` — all present on every core in the `~> 2.0` pin range,
per-instant on any core that knows ids), so a named zone follows daylight
saving on the date shown.

**Never turn the value into one number and add it** (`offset_to_seconds/1` is
deprecated in core): that read every id as 0 on older cores and was an hour
off across every DST switch after — the day window (`Events.window_bounds/3`,
each bound resolved at its own date), the page's `today` (the viewer's date,
not `Date.utc_today/0`) and the modal's zone identity all had it.

Concretely, in `Events`: the window is `[local midnight of from, local midnight
of until)`, each bound resolved AT ITS OWN DATE via `parse_datetime_local/2`
(`local_midnight/2`). Subtracting a single "offset today" from both bounds is
wrong for any window on the other side of a daylight-saving switch: a Tallinn
viewer opening January from September got bounds an hour early (today's +3
applied to a +2 month), so the last local hour of January 31 fell out of the
month and the last hour of December 31 leaked in. An unresolvable zone value
falls back to UTC midnight.

## The modal's input frame

The LV keeps an "input frame" (`@input_tz`): the changeset always holds UTC;
`localize_times/2` converts typed wall-clock → UTC using the frame the values
were DISPLAYED in (convert with the old frame BEFORE recomputing it, or the
checkbox toggle would shift the instant); `datetime_local_value/2` converts
back at render (handles both cast DateTimes and raw ISO params —
`FormField.value` prefers params). `assign_tz_frame/2` recomputes the frame at
open and on every validate, because the owner picker can change the target
calendar mid-edit.

## Cross-timezone entry

When the target owner's zone and the viewer's would EVER show a different wall
clock, the modal shows an indicator (core's `Settings.get_timezone_label/1`
labels) plus a "Use their timezone" checkbox (`owner_tz_entry`, outside the
changeset) that switches the display/entry frame — same instant, different
digits.

"Would these ever differ?" is `tz_differs?/2`:

- Two IANA ids are compared by their daylight-saving RULE
  (`PhoenixKit.Utils.TimeZone.effectively_same?/2`, which groups zones that
  behave identically all year). An offset comparison is the wrong question —
  two zones can share an offset today and diverge in March, and the answer
  would flip under the user without either value changing.
- Anything involving a legacy offset is compared by a fortnightly **year
  signature** (`year_signature/1`: what noon means in UTC on the 1st and 15th
  of every month this year). A fixed offset gives the same answer all year, so
  it equals a zone only if that zone never moves. Twice a month rather than
  once a season because `Africa/Casablanca` is UTC+1 in January AND July and
  drops to UTC+0 only for Ramadan, a month that wanders through the year.
  Core's `effectively_same?/2` compares the offset *right now* for a mixed
  pair — right for its own "is your browser somewhere else today?" nudge, and
  exactly the flip this function must not have.
- `TimeZone` is feature-detected (`Code.ensure_loaded?/1` AND
  `function_exported?/3` — the latter alone answers false for a module that
  has merely not been loaded, the normal state under a release). The
  `:phoenix_kit` requirement stays a two-segment `~> 2.0` on purpose —
  narrowing it to one core minor makes `mix deps.get` unsolvable for any host
  running this module beside a different core
  (`test/core_pin_conformance_test.exs`). An older core has no identifiers to
  tell apart and every value takes the signature path.
- A nil/`""` value (meaning "use the site default") is normalised to the site
  setting before comparing (`normalize_tz/1`).

The owner's zone for someone else's calendar comes from the loaded people
list (`person.tz`), with a direct `user_timezone` lookup as the fallback and
the site default when that is blank.

## Widgets

Every helper in `Web.WidgetSupport` answers in the VIEWER's frame —
`viewer_tz/1`, `local_today/1`, `occupied_dates/2`, `on_date?/3` and
`sort_key/2`. `sort_key/2` takes the tz for a reason: an all-day `starts_on`
is a LOCAL date and `starts_at` is a true UTC instant, so comparing the two
raw sorted an early-morning timed event ahead of its own day's all-day rows for
every viewer east of UTC (02:00 in Tallinn is 23:00Z the day before) — the
timed key is the viewer's wall clock, labelled UTC so the two compare.

## Testing rule

Tests MUST use IANA values and a window in the opposite season from "now"
(or a north+south pair such as `Europe/Tallinn` + `America/Santiago`) — a
suite of `"3"`s hides every one of the bugs above, because a fixed offset
never crosses a DST switch.

## Pending collapse

Once the core floor reaches the release with `TimeZone.for_viewer/1`,
`date_start/2` and `local_date/2`, the private `viewer_timezone/2`,
`WidgetSupport.viewer_tz/1`/`local_today/1` and `Events.local_midnight/2`
collapse into those.
