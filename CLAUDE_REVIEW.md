# Review: PR #2 — Calendar module (personal calendars, fine-grained permissions, quality sweep)

Reviewed against the invariants documented in `AGENTS.md`. Scope: the full initial
module (`lib/phoenix_kit_calendar/**`, `test/**`) merged in PR #2, current as of
`a51468e` (merge) / `ce7bb44` (mix.lock bump, no source changes since).

Methodology: five focused passes — Events context authorization, Participants/Sources
leak control, `CalendarLive` LiveView, dashboard widgets + main module, and test
coverage against the documented invariants — each independently verifying AGENTS.md's
claims against the actual code (not trusting the doc), with a follow-up direct
`Enum.sort_by/2` term-order check in an IEx session to confirm the most significant
finding before fixing it.

## Findings

### BUG-HIGH — dashboard widgets sort chronologically-wrong across month boundaries

`lib/phoenix_kit_calendar/web/upcoming_widget.ex` and
`lib/phoenix_kit_calendar/web/today_agenda_widget.ex` both called:

```elixir
Enum.sort_by(&WidgetSupport.sort_key/1)
```

`sort_key/1` returns a `DateTime.t()`. Without an explicit comparator,
`Enum.sort_by/2` uses raw Erlang term ordering, and `%DateTime{}`'s fields compare
alphabetically by key — `day` before `month` before `year`. Verified directly:

```
Enum.sort_by([~U[2026-08-05 09:00:00Z], ~U[2026-07-20 09:00:00Z]], & &1)
#=> [~U[2026-08-05 09:00:00Z], ~U[2026-07-20 09:00:00Z]]   # August before July — wrong
```

- **Upcoming** (60-day horizon): "soonest first" breaks on most renders once the
  window crosses a month boundary — which it does on the majority of days in a month.
- **Today**: degenerates harmlessly within a single day, except for a multi-day
  all-day event that started in an earlier month and is still active today — it can
  sort after same-day timed events, violating "all-day first."
- The existing pinning tests (`widget_test.exs`) only used events 0–4 days apart,
  always within one month, so this never fired.

**Fix applied:** `Enum.sort_by(&WidgetSupport.sort_key/1, DateTime)` in both files —
passing the `DateTime` module uses `DateTime.compare/2`. Locked in with a new test,
`test/phoenix_kit_calendar/web/widget_test.exs` — "Upcoming stays soonest-first even
when day-of-month decreases" — which computes a real month-boundary date pair,
inserts the events out of chronological order, and asserts render order.

### IMPROVEMENT-HIGH — `CalendarLive.mount/3` queried the DB and the result never refreshed

`lib/phoenix_kit_calendar/web/calendar_live.ex` `mount/3` called `load_people/1`
(3 DB round trips: user list + two permission/role queries) unconditionally — not
gated by `connected?(socket)` like the PubSub subscribe two lines above it, so it ran
on both the disconnected static-render mount and the connected websocket mount
(duplicate query on every page load), and — because `mount/3` only runs once —
`:people` was never reassigned anywhere else in the file. A user created, or whose
calendar access changed, after the socket connected would never appear in the
"Calendars" panel, the owner picker, or `sanitize_owner/2`'s known-people check for
the entire life of that socket. This is exactly the "no DB queries in `mount/3`"
Iron Law the codebase otherwise follows carefully (events/window-count reloads
already live in `handle_params`/`handle_info`, re-run against the fresh scope on
every navigation).

Not a security hole — every mutation path independently re-authorizes against the
persisted owner via the context regardless of what `:people` shows — but a real
functional staleness + duplicate-query bug.

**Fix applied:** moved the `load_people/1` call out of `mount/3` (now assigns `[]`)
and into `handle_params/3`, before `sanitize_selection/2` (which depends on it),
matching the file's own "reload against fresh state on every navigation" convention
used everywhere else. Locked in with a new test,
`test/phoenix_kit_calendar/web/calendar_live_test.exs` — "a person created after
connecting appears once the panel reloads (not a mount-time copy)".

### IMPROVEMENT-MEDIUM — activity-log failure could silently drop the PubSub broadcast

`lib/phoenix_kit_calendar/events.ex` `tap_log/4` ran `PhoenixKit.Activity.log/1` and
`broadcast_event_changed/1` inside the same `rescue`. The comment states logging
failure "never breaks the primary operation," but as written, an exception from
`Activity.log/1` would also skip the broadcast that runs after it in source order —
silently dropping the live cross-tab update for that mutation, not just the audit
record.

**Fix applied:** split activity logging into its own `log_activity/4` with its own
`rescue`, so `broadcast_event_changed/1` always runs after a successful mutation
regardless of logging outcome. No behavior change on the happy path; not separately
tested (would require forcing `PhoenixKit.Activity.log/1` to raise, which the test
suite has no seam for and isn't worth adding one for this fix's size).

### Verified clean (no action needed)

- **Events context** (`events.ex`, `schemas/event.ex`, `paths.ex`): every public
  function authorizes against the target owner via `Scope.can?/2`; mutations are
  genuinely load-then-authorize (`reload_and_authorize/3` discards every caller-struct
  field but `uuid` before reloading and checking the persisted owner);
  `owner_uuid` is absent from `cast/3` and only ever set via `put_change` after
  changeset validation — no smuggling path; the `all_day` nilling is bidirectional
  and matches the DB CHECK; `status`/`color` are real allowlists
  (`validate_inclusion/3` + DB CHECK), not format checks. Two pre-existing NITPICKs
  noted but not fixed (over-engineering risk for their likelihood): no
  `foreign_key_constraint(:owner_uuid)` (an FK violation would raise
  `Ecto.ConstraintError` instead of returning `{:error, changeset}` — low risk since
  callers only ever pass a scope-derived or UI-clamped real user uuid), and no
  optimistic lock on `update_event`/`delete_event` (narrow concurrent-delete window,
  cosmetic impact only).
- **Participants/Sources** (`participants.ex`, `sources.ex`,
  `schemas/participant.ex`): cross-source dedup precedence (user > staff > contact,
  unlinked always survives) is correctly implemented via a single `seen` MapSet
  threaded in source-priority order; search results are genuinely name+icon+sublabel
  only, no PII leak; the `limit+1`-per-source / `has_more` pagination has no
  off-by-one, computed from pre-dedup counts so dedup can't produce a false "no
  more"; source filtering happens *before* querying (no existence/count leak for
  disallowed sources); free-text participants are structurally excluded from
  notification (`resolve_user/1` has no clause for `kind: "free_text"`).
  One IMPROVEMENT-MEDIUM nitpick left as-is: `canonicalize_added/1`/`notify_added/3`
  issue one query per newly-added participant — bounded by how many people a human
  adds in one save, not attacker-controlled, so real-world impact is negligible.
- **`CalendarLive`** (beyond the mount finding above): subscribe-before-first-read is
  correct; the `{:calendar_event_changed, owner_uuid}` handler's in-view comparison is
  correct and reloads against the fresh scope, not a mount-time closure; the
  timezone frame-conversion ordering (`@input_tz` used to convert *before* it's
  recomputed on a checkbox toggle — the exact bug class AGENTS.md warns about) is
  correct; the inclusive/exclusive all-day date shift is applied exactly once per
  direction with no double-shift; authorization is genuinely mirror-only — every
  mutation handler still routes through the context's real authorization.
- **Widgets/main module** (beyond the sort bug above): all three widgets query
  strictly through the viewer's own `scope` (no bypass, no `Repo` calls in widget
  code); nil scope/settings/size degrade to an empty state rather than raising;
  the 60-day horizon, `limit`, and `show_location` settings are genuinely honored,
  not hardcoded; `mini_month`'s day-bucketing and month-boundary math are correct,
  cancelled events excluded; all UI strings go through `gettext/1`.
  Minor doc-completeness gap (not a code bug): `permission_metadata/0` declares
  three additional invite-scoped sub-permissions
  (`invite_platform_users`/`invite_staff`/`invite_crm`) that are real and correctly
  enforced but absent from AGENTS.md's summary permission table.

## Test coverage gaps (not fixed — flagged for a follow-up PR)

The test-suite review found two documented invariants with **zero** coverage at the
`CalendarLive` layer (the context-level equivalents are well tested):

1. **PubSub-driven selective reload** — no test drives a live `view.pid` with
   `{:calendar_event_changed, owner_uuid}` to confirm a viewed owner reloads and a
   non-viewed owner doesn't. `edge_and_pubsub_test.exs` only proves the context
   broadcasts to a raw `Phoenix.PubSub` subscriber, never through a real LiveView.
2. **Mid-session permission revocation** — no test mutates a running LiveView's
   scope between two interactions to confirm a revoked `view_others`/`edit_others`
   doesn't retain stale access from mount. `test/support/hooks.ex` only assigns
   scope once, at mount.

These weren't introduced by this PR's fixes, so they're out of scope for this pass,
but they're the highest-value next tests given how central "fresh scope, not a
mount-time copy" is to this module's whole security story.

## Validation gate

Run with `PHOENIX_KIT_PATH=../phoenix_kit` per AGENTS.md's cross-repo-gate note:

- `mix format` — clean (only the intentionally-edited files changed).
- `mix compile --warnings-as-errors` (dev) and `MIX_ENV=test mix compile --warnings-as-errors --force` — clean, no warnings.
- `mix credo --strict` — 339 mods/funs analyzed, no issues.
- `mix test` — **could not run the DB-backed portion**: this sandbox has no
  PostgreSQL server and no root access to install/start one (`apt-get install
  postgresql` fails with "are you root?"). The 11 DB-independent tests that do
  run (defensive-default / no-database-connection tests) pass; the other 98 are
  tagged and skipped for lack of a DB connection, which is expected in an
  environment without Postgres, not a code failure. Since `mix test` compiles
  the entire suite before filtering by tag, this run did confirm every touched
  test file — including the two new regression tests added in this review —
  compiles without error. **The DB-backed suite (`mix test.setup && mix test`)
  should still be run in a real environment with Postgres before this is
  merged/released**, since that's the only way to actually execute the new
  regression tests and the rest of the suite.

## Not addressed

Per `AGENTS.md`: **"Releases/version bumps are Max-only — PRs land at the current
version."** No version bump, CHANGELOG entry, or Hex publish was performed as part
of this review, regardless of how the review was invoked.
