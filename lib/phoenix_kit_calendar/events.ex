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
  alias PhoenixKitCalendar.Schemas.Event

  @base_key "calendar"
  @view_others "calendar.view_others"
  @edit_others "calendar.edit_others"

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
  @spec list_events(Scope.t() | nil, String.t(), Date.t(), Date.t()) ::
          {:ok, [Event.t()]} | {:error, :unauthorized}
  def list_events(scope, owner_uuid, %Date{} = from, %Date{} = until) do
    with :ok <- authorize(scope, owner_uuid, :view) do
      from_dt = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
      until_dt = DateTime.new!(until, ~T[00:00:00], "Etc/UTC")

      events =
        from(e in Event,
          where: e.owner_uuid == ^owner_uuid,
          where:
            (not e.all_day and e.starts_at < ^until_dt and e.ends_at > ^from_dt) or
              (e.all_day and e.starts_on < ^until and e.ends_on > ^from),
          order_by: [asc: e.starts_at, asc: e.starts_on]
        )
        |> repo().all()

      {:ok, events}
    end
  end

  @doc """
  Fetches one event, authorizing READ access against its persisted owner.
  """
  @spec get_event(Scope.t() | nil, String.t()) ::
          {:ok, Event.t()} | {:error, :not_found | :unauthorized}
  def get_event(scope, uuid) do
    with %Event{} = event <- repo().get(Event, uuid) || {:error, :not_found},
         :ok <- authorize(scope, event.owner_uuid, :view) do
      {:ok, event}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Map of `owner_uuid => event count` across all calendars. Powers the
  person switcher's "has events" annotation, so it requires cross-calendar
  read access (`calendar.view_others` / `calendar.edit_others`).
  """
  @spec count_events_by_owner(Scope.t() | nil) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, :unauthorized}
  def count_events_by_owner(scope) do
    if Scope.can?(scope, @view_others) or Scope.can?(scope, @edit_others) do
      counts =
        from(e in Event,
          group_by: e.owner_uuid,
          select: {e.owner_uuid, count(e.uuid)}
        )
        |> repo().all()
        |> Map.new()

      {:ok, counts}
    else
      {:error, :unauthorized}
    end
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
          {:ok, Event.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def update_event(scope, %Event{} = event, attrs, opts \\ []) do
    with :ok <- authorize(scope, event.owner_uuid, :edit) do
      event
      |> Event.changeset(attrs)
      |> repo().update()
      |> tap_log("calendar_event.updated", scope, opts)
    end
  end

  @doc """
  Deletes an event. Same load-then-authorize rule as `update_event/4`.
  """
  @spec delete_event(Scope.t() | nil, Event.t(), keyword()) ::
          {:ok, Event.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def delete_event(scope, %Event{} = event, opts \\ []) do
    with :ok <- authorize(scope, event.owner_uuid, :edit) do
      event
      |> repo().delete()
      |> tap_log("calendar_event.deleted", scope, opts)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp repo, do: RepoHelper.repo()

  # Activity logging — guarded so a logging failure (or core without the
  # Activity module) never breaks the primary operation. Metadata carries the
  # title and the owning calendar; note the activity feed's visibility is
  # broader than calendar permissions, so nothing more sensitive goes in.
  defp tap_log({:ok, %Event{} = event} = result, action, scope, opts) do
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
          "title" => event.title,
          "owner_uuid" => event.owner_uuid
        }
      })
    end

    result
  rescue
    _ -> result
  end

  defp tap_log(result, _action, _scope, _opts), do: result
end
