defmodule PhoenixKitCalendar.Events do
  @moduledoc """
  Context for personal calendar events — CRUD with scope-based
  authorization built into every function.

  ## Authorization model

  Every function takes the caller's `PhoenixKit.Users.Auth.Scope` and
  authorizes against the TARGET calendar's owner:

  | Caller vs target | Needs |
  |------------------|-------|
  | Own calendar | `calendar` |
  | Someone else's, reading | `calendar.view_others` (or `edit_others`, which implies view) |
  | Someone else's, writing | `calendar.edit_others` |

  All checks go through `Scope.can?/2`, so they also require the calendar
  module to be enabled — a stale scope can't keep operating after the
  module is switched off.

  Two invariants hold regardless of the calling UI:

  - `owner_uuid` is never taken from user-supplied attrs. Creation takes
    it as an explicit, separately-authorized argument; the schema doesn't
    cast it; updates can't move an event to another calendar.
  - Mutations on existing events are load-then-authorize: the event's
    PERSISTED owner decides the required permission, not anything the
    caller claims.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Date, as: DateUtils
  alias PhoenixKitCalendar.Schemas.Event

  @base_key "calendar"
  @view_others "calendar.view_others"
  @edit_others "calendar.edit_others"

  # Single PubSub topic for live cross-session updates. Subscribers filter the
  # `{:calendar_event_changed, owner_uuid}` payload against their current view.
  @pubsub_topic "phoenix_kit_calendar:events"

  @doc """
  The PubSub topic carrying `{:calendar_event_changed, owner_uuid}` after every
  committed create/update/delete. A LiveView showing calendars subscribes and
  reloads when a change lands for an owner in its current view.
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  # ===========================================================================
  # Authorization
  # ===========================================================================

  @doc """
  Whether the scope may READ the calendar owned by `owner_uuid`.
  Own calendar needs `calendar`; others' need `calendar.view_others`
  (or `calendar.edit_others`, which implies viewing).
  """
  @spec can_view?(Scope.t() | nil, String.t()) :: boolean()
  def can_view?(scope, owner_uuid) do
    if own?(scope, owner_uuid) do
      Scope.can?(scope, @base_key)
    else
      Scope.can?(scope, @view_others) or Scope.can?(scope, @edit_others)
    end
  end

  @doc """
  Whether the scope may WRITE (create/update/delete events) on the
  calendar owned by `owner_uuid`. Own calendar needs `calendar`;
  others' need `calendar.edit_others`.
  """
  @spec can_edit?(Scope.t() | nil, String.t()) :: boolean()
  def can_edit?(scope, owner_uuid) do
    if own?(scope, owner_uuid) do
      Scope.can?(scope, @base_key)
    else
      Scope.can?(scope, @edit_others)
    end
  end

  defp own?(scope, owner_uuid) do
    case scope && Scope.user(scope) do
      %{uuid: uuid} when not is_nil(uuid) -> uuid == owner_uuid
      _ -> false
    end
  end

  defp authorize(scope, owner_uuid, :view) do
    if can_view?(scope, owner_uuid), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize(scope, owner_uuid, :edit) do
    if can_edit?(scope, owner_uuid), do: :ok, else: {:error, :unauthorized}
  end

  # ===========================================================================
  # Queries
  # ===========================================================================

  @doc """
  Lists the events on `owner_uuid`'s calendar overlapping the given
  window (both bounds are dates; the window is `[from, until)`).

  Returns `{:ok, events}` or `{:error, :unauthorized}`.
  """
  @spec list_events(Scope.t() | nil, String.t(), Date.t(), Date.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, :unauthorized}
  def list_events(scope, owner_uuid, %Date{} = from, %Date{} = until, opts \\ []) do
    with :ok <- authorize(scope, owner_uuid, :view) do
      {from_dt, until_dt} = window_bounds(from, until, Keyword.get(opts, :viewer_tz, "0"))

      # a person's schedule = events they OWN plus events they PARTICIPATE
      # in (live resolution — see participant_visible_dynamic/1)
      visible = dynamic([e], e.owner_uuid == ^owner_uuid)
      visible = dynamic([e], ^visible or ^participant_visible_dynamic([owner_uuid]))

      events =
        from(e in Event,
          where: ^visible,
          where: ^overlapping_window(from, until, from_dt, until_dt),
          order_by: [asc: e.starts_at, asc: e.starts_on]
        )
        |> repo().all()
        |> resolve_live_locations()

      {:ok, events}
    end
  end

  @doc """
  Lists EVERYONE's events overlapping the window — the combined "who is
  busy when" view. Requires cross-calendar read access
  (`calendar.view_others` / `calendar.edit_others`); a caller with only
  the base key gets `{:error, :unauthorized}`.

  ## Options

  - `:owner_uuids` — restrict to these calendars (the person-filter
    toggles in the Everyone view). Omit or `nil` for all calendars.
  """
  @spec list_all_events(Scope.t() | nil, Date.t(), Date.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, :unauthorized}
  def list_all_events(scope, %Date{} = from, %Date{} = until, opts \\ []) do
    if Scope.can?(scope, @view_others) or Scope.can?(scope, @edit_others) do
      {from_dt, until_dt} = window_bounds(from, until, Keyword.get(opts, :viewer_tz, "0"))

      events =
        from(e in Event,
          where: ^overlapping_window(from, until, from_dt, until_dt),
          order_by: [asc: e.starts_at, asc: e.starts_on]
        )
        |> maybe_filter_owners(Keyword.get(opts, :owner_uuids))
        |> repo().all()
        |> resolve_live_locations()

      {:ok, events}
    else
      {:error, :unauthorized}
    end
  end

  defp maybe_filter_owners(query, nil), do: query

  defp maybe_filter_owners(query, owner_uuids) when is_list(owner_uuids) do
    # each selected person contributes their OWNED events plus the events
    # they currently PARTICIPATE in
    visible = dynamic([e], e.owner_uuid in ^owner_uuids)
    visible = dynamic([e], ^visible or ^participant_visible_dynamic(owner_uuids))
    from(e in query, where: ^visible)
  end

  @doc """
  Fetches one event, authorizing READ access against its persisted owner.
  """
  @spec get_event(Scope.t() | nil, String.t()) ::
          {:ok, Event.t()} | {:error, :not_found | :unauthorized}
  def get_event(scope, uuid) do
    # a forged/malformed event id (non-UUID string from a spoofed hook
    # payload) makes repo().get raise Ecto.Query.CastError — treat it as
    # a missing event, not a socket crash.
    case safe_get(uuid) do
      nil ->
        {:error, :not_found}

      %Event{} = event ->
        if readable?(scope, event) do
          {:ok, resolve_live_locations(event)}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Whether the scope may READ this event: owner-level view access, OR being a
  live-resolved participant of THIS event (which grants visibility of this
  event only, never the rest of the owner's calendar). Both require the
  calendar module to be enabled — module off seals every path.

  This is the single authorization predicate the participant read paths share
  with `get_event/2`, so a participant sees the event AND its participant list
  under the same rule.
  """
  @spec readable?(Scope.t() | nil, Event.t()) :: boolean()
  def readable?(scope, %Event{} = event) do
    authorize(scope, event.owner_uuid, :view) == :ok or
      (calendar_enabled?() and participant?(scope, event))
  end

  defp safe_get(uuid) do
    repo().get(Event, uuid)
  rescue
    # A non-UUID id → CastError → treat as "no such event". A real DB error
    # is left to propagate rather than masquerading as :not_found.
    Ecto.Query.CastError -> nil
  end

  defp calendar_enabled?, do: Permissions.feature_enabled?("calendar")

  @doc """
  Whether the scope's user currently resolves as a participant of the
  event (live — see `participant_visible_dynamic/1`). A pure predicate:
  callers making ACCESS decisions must combine it with module enablement,
  as `get_event/2` does.
  """
  @spec participant?(Scope.t() | nil, Event.t()) :: boolean()
  def participant?(scope, %Event{} = event) do
    case scope && Scope.user_uuid(scope) do
      nil ->
        false

      user_uuid ->
        from(e in Event, where: e.uuid == ^event.uuid)
        |> where(^participant_visible_dynamic([user_uuid]))
        |> repo().exists?()
    end
  rescue
    _ -> false
  end

  @doc """
  Map of `owner_uuid => count of events they OWN` across all calendars.
  Requires cross-calendar read access (`calendar.view_others` /
  `calendar.edit_others`).

  Pass a `from`/`until` date window to count only events overlapping it —
  that powers the person panel's "empty" badge, which flags a person whose
  own calendar has no events in the visible range. The count is
  ownership-scoped by design: the badge answers "is this CALENDAR empty
  here" (the panel picks calendars to view), not "would soloing them show
  nothing" — soloing additionally overlays events on OTHER calendars they
  merely participate in, which belong to those owners' counts.
  """
  @spec count_events_by_owner(Scope.t() | nil, Date.t() | nil, Date.t() | nil, keyword()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, :unauthorized}
  def count_events_by_owner(scope, from \\ nil, until \\ nil, opts \\ []) do
    if Scope.can?(scope, @view_others) or Scope.can?(scope, @edit_others) do
      counts =
        from(e in Event,
          group_by: e.owner_uuid,
          select: {e.owner_uuid, count(e.uuid)}
        )
        |> maybe_window(from, until, Keyword.get(opts, :viewer_tz, "0"))
        |> repo().all()
        |> Map.new()

      {:ok, counts}
    else
      {:error, :unauthorized}
    end
  end

  defp maybe_window(query, %Date{} = from, %Date{} = until, viewer_tz) do
    {from_dt, until_dt} = window_bounds(from, until, viewer_tz)
    from(e in query, where: ^overlapping_window(from, until, from_dt, until_dt))
  end

  defp maybe_window(query, _from, _until, _viewer_tz), do: query

  # Half-open `[from, until)` overlap for BOTH timed events (UTC datetime pair)
  # and all-day events (date pair). Defined once so every windowed query agrees
  # — the three views must match bit-for-bit or they'd disagree on edges.
  defp overlapping_window(from, until, from_dt, until_dt) do
    dynamic(
      [e],
      (not e.all_day and e.starts_at < ^until_dt and e.ends_at > ^from_dt) or
        (e.all_day and e.starts_on < ^until and e.ends_on > ^from)
    )
  end

  # The UTC instants bounding a VIEWER-LOCAL day window. Timed events are
  # stored in UTC and displayed shifted by the viewer offset, so the viewer's
  # [from, until) day range maps to the UTC half-open interval
  # [from 00:00 - offset, until 00:00 - offset). Without this shift, timed
  # events within `offset` hours of UTC midnight fall out of the very window
  # the grid places them in (all-day events use bare dates and need no shift).
  defp window_bounds(from, until, viewer_tz) do
    offset = DateUtils.offset_to_seconds(viewer_tz)

    {
      DateTime.new!(from, ~T[00:00:00], "Etc/UTC") |> DateTime.add(-offset, :second),
      DateTime.new!(until, ~T[00:00:00], "Etc/UTC") |> DateTime.add(-offset, :second)
    }
  end

  # ===========================================================================
  # Mutations
  # ===========================================================================

  @doc """
  Creates an event on `owner_uuid`'s calendar.

  `owner_uuid` is an explicit argument — never read from `attrs` — and is
  authorized before the changeset ever runs. `opts` may carry `:actor_uuid`
  for activity logging (defaults to the scope's user).
  """
  @spec create_event(Scope.t() | nil, String.t(), map(), keyword()) ::
          {:ok, Event.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_event(scope, owner_uuid, attrs, opts \\ []) do
    with :ok <- authorize(scope, owner_uuid, :edit) do
      %Event{}
      |> Event.changeset(attrs)
      |> Ecto.Changeset.put_change(:owner_uuid, owner_uuid)
      |> snapshot_location()
      |> repo().insert()
      |> tap_log("calendar_event.created", scope, opts)
    end
  end

  @doc """
  Updates an event. Authorization runs against the event's PERSISTED
  owner (load-then-authorize); the changeset cannot move the event to a
  different calendar because `owner_uuid` is not castable.
  """
  @spec update_event(Scope.t() | nil, Event.t(), map(), keyword()) ::
          {:ok, Event.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_event(scope, %Event{} = event, attrs, opts \\ []) do
    # Reload and authorize the PERSISTED owner, not the caller's in-memory
    # struct: Ecto updates by primary key, so a struct carrying a forged
    # owner_uuid would otherwise pass the check yet mutate the real row.
    # This makes the moduledoc's "load-then-authorize" guarantee real for
    # every caller, not just the LiveView that happens to pass a fresh row.
    with {:ok, fresh} <- reload_and_authorize(scope, event, :edit) do
      fresh
      |> Event.changeset(attrs)
      |> snapshot_location()
      |> repo().update()
      |> tap_log("calendar_event.updated", scope, opts)
    end
  end

  @doc """
  Deletes an event. Same load-then-authorize rule as `update_event/4`.
  """
  @spec delete_event(Scope.t() | nil, Event.t(), keyword()) ::
          {:ok, Event.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def delete_event(scope, %Event{} = event, opts \\ []) do
    with {:ok, fresh} <- reload_and_authorize(scope, event, :edit) do
      fresh
      |> repo().delete()
      |> tap_log("calendar_event.deleted", scope, opts)
    end
  end

  # Reloads the event by uuid and authorizes the action against its CURRENT
  # persisted owner. Returns `{:ok, fresh_event}`, `{:error, :not_found}` if
  # it was deleted meanwhile, or `{:error, :unauthorized}`.
  defp reload_and_authorize(scope, %Event{uuid: uuid}, action) do
    case repo().get(Event, uuid) do
      nil ->
        {:error, :not_found}

      %Event{} = fresh ->
        with :ok <- authorize(scope, fresh.owner_uuid, action), do: {:ok, fresh}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp repo, do: RepoHelper.repo()

  # LIVE participant visibility: true when any participant row of the event
  # resolves to one of `user_uuids` RIGHT NOW. Resolution joins the PHYSICAL
  # staff/CRM tables (they exist in every install via core migrations, so no
  # module code is needed; empty tables no-op). A company participant means
  # "whoever is a member of that company at query time" — the boss's explicit
  # choice (2026-07-09) over save-time snapshots.
  defp participant_visible_dynamic(user_uuids) do
    dynamic(
      [e],
      fragment(
        """
        EXISTS (
          SELECT 1 FROM phoenix_kit_calendar_event_participants p
          WHERE p.event_uuid = ?
            AND (
              (p.kind = 'user' AND p.target_uuid = ANY(?))
              OR (p.kind = 'staff_person' AND EXISTS (
                    SELECT 1 FROM phoenix_kit_staff_people sp
                    WHERE sp.uuid = p.target_uuid
                      AND sp.status <> 'trashed'
                      AND sp.user_uuid = ANY(?)))
              OR (p.kind = 'crm_contact' AND EXISTS (
                    SELECT 1 FROM phoenix_kit_crm_contacts c
                    WHERE c.uuid = p.target_uuid
                      AND c.status <> 'trashed'
                      AND c.user_uuid = ANY(?)))
              OR (p.kind = 'crm_company' AND EXISTS (
                    SELECT 1 FROM phoenix_kit_crm_company_memberships m
                    JOIN phoenix_kit_crm_contacts c2 ON c2.uuid = m.contact_uuid
                    JOIN phoenix_kit_crm_companies co ON co.uuid = m.company_uuid
                    WHERE m.company_uuid = p.target_uuid
                      AND co.status <> 'trashed'
                      AND c2.status <> 'trashed'
                      AND c2.user_uuid = ANY(?)))
            )
        )
        """,
        e.uuid,
        type(^user_uuids, {:array, UUIDv7}),
        type(^user_uuids, {:array, UUIDv7}),
        type(^user_uuids, {:array, UUIDv7}),
        type(^user_uuids, {:array, UUIDv7})
      )
    )
  end

  # Rewrites each loaded event's display `location` to the LINKED
  # location's CURRENT name (schemaless batch lookup — the table exists in
  # every install). The stored string is only the save-time snapshot and
  # serves as the fallback when the location row is gone or trashed — so
  # renaming a location propagates to every event linked by uuid.
  defp resolve_live_locations(events) when is_list(events) do
    uuids =
      events
      |> Enum.map(& &1.location_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if uuids == [] do
      events
    else
      names =
        from(l in "phoenix_kit_locations",
          where: l.uuid in type(^uuids, {:array, UUIDv7}) and l.status != "trashed",
          select: {type(l.uuid, UUIDv7), l.name}
        )
        |> repo().all()
        |> Map.new()

      Enum.map(events, &put_live_location(&1, names))
    end
  rescue
    # a failed lookup must never break listing — the snapshots suffice
    _ -> events
  end

  defp resolve_live_locations(%Event{} = event) do
    [event] |> resolve_live_locations() |> hd()
  end

  defp put_live_location(event, names) do
    case event.location_uuid && Map.get(names, event.location_uuid) do
      name when is_binary(name) and name != "" -> %{event | location: name}
      _ -> event
    end
  end

  # Snapshot the picked location's name into the free-text column so
  # rendering never needs the locations module — but it is only the
  # FALLBACK: display resolves the current name live via
  # resolve_live_locations/1. A cleared/absent pick keeps whatever the
  # user typed.
  defp snapshot_location(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.get_change(changeset, :location_uuid) do
      nil ->
        changeset

      location_uuid ->
        name =
          from(l in "phoenix_kit_locations",
            where: l.uuid == type(^location_uuid, UUIDv7) and l.status != "trashed",
            select: l.name
          )
          |> repo().one()

        if is_binary(name) do
          Ecto.Changeset.put_change(changeset, :location, name)
        else
          Ecto.Changeset.put_change(changeset, :location_uuid, nil)
        end
    end
  rescue
    _ -> changeset
  end

  # Activity logging — guarded so a logging failure (or core without the
  # Activity module) never breaks the primary operation.
  #
  # PRIVACY: the core activity feed (`/admin/activity`) is visible to any
  # holder of the dashboard/activity permission — BROADER than calendar
  # permissions — and renders all metadata. The event TITLE is private
  # calendar content ("Private medical appointment"), so it must NOT go into
  # this globally-readable record; only the resource uuid + owning calendar
  # (both uuids) are logged. A richer, permission-scoped activity feed is the
  # right long-term home for titles — tracked as a follow-up.
  defp tap_log({:ok, %Event{} = event} = result, action, scope, opts) do
    log_activity(event, action, scope, opts)
    broadcast_event_changed(event.owner_uuid)
    result
  end

  defp tap_log(result, _action, _scope, _opts), do: result

  # Isolated from broadcast_event_changed/1: a logging failure must never
  # suppress the live-update broadcast for a successful mutation.
  defp log_activity(event, action, scope, opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      actor_uuid = Keyword.get(opts, :actor_uuid, scope && Scope.user_uuid(scope))

      PhoenixKit.Activity.log(%{
        action: action,
        module: "calendar",
        mode: "manual",
        actor_uuid: actor_uuid,
        resource_type: "calendar_event",
        resource_uuid: event.uuid,
        metadata: %{
          "owner_uuid" => event.owner_uuid
        }
      })
    end
  rescue
    _ -> :ok
  end

  # Announce a committed change with a minimal payload (owner uuid only — no
  # record, no PII). No-op when the host configures no PubSub server.
  defp broadcast_event_changed(owner_uuid) do
    case PhoenixKit.Config.pubsub_server() do
      nil ->
        :ok

      pubsub ->
        Phoenix.PubSub.broadcast(pubsub, @pubsub_topic, {:calendar_event_changed, owner_uuid})
    end
  rescue
    _ -> :ok
  end
end
