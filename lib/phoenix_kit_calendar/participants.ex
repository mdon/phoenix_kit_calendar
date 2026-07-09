defmodule PhoenixKitCalendar.Participants do
  @moduledoc """
  Attaching people to calendar events.

  ## Authorization

  Editing an event's participants requires edit access to the event
  (`PhoenixKitCalendar.Events.can_edit?/2` semantics). Per-KIND gating on
  top (quorum-hardened, and validated HERE — never only in the UI):

  | kind | requires |
  |------|----------|
  | `user` | `calendar.invite_platform_users` |
  | `staff_person` | `calendar.invite_staff` + staff module enabled |
  | `crm_contact` / `crm_company` | `calendar.invite_crm` + CRM module enabled |
  | `free_text` | nothing beyond event edit access |

  ## Replace semantics

  `replace_participants/3` is a full-replace-with-diff inside one
  transaction: rows not in the new set are deleted (visibility revoked
  immediately), new entries are inserted, unchanged rows are kept
  untouched. Only NEWLY added entries notify — each is live-resolved to a
  platform user (`PhoenixKitCalendar.Sources.resolve_user/1`) and logged
  with `target_uuid`, which core's notification system fans out to an
  in-app notification. Company adds create no per-member notifications
  (members see the event via live visibility instead).
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixKitCalendar.Schemas.Participant
  alias PhoenixKitCalendar.Sources

  @doc """
  Lists an event's participants (insertion order).
  """
  @spec list_for_event(String.t()) :: [Participant.t()]
  def list_for_event(event_uuid) do
    from(p in Participant,
      where: p.event_uuid == ^event_uuid,
      order_by: [asc: p.inserted_at, asc: p.uuid]
    )
    |> repo().all()
  end

  @doc """
  Replaces the event's participant set with `entries`
  (`[%{kind, target_uuid, display_name}]`), diffing against the current
  rows. Returns `{:ok, participants}` or `{:error, :unauthorized}` /
  `{:error, changeset}`.

  Authorization: event edit access, plus the per-kind invite permission
  for every NEWLY ADDED entry (existing rows of a kind the editor can't
  grant are preserved — an editor without `invite_crm` can't add clients
  but doesn't silently strip someone else's).
  """
  @spec replace_participants(Scope.t() | nil, Event.t(), [map()]) ::
          {:ok, [Participant.t()]} | {:error, :unauthorized | Ecto.Changeset.t()}
  def replace_participants(scope, %Event{} = event, entries) do
    entries = normalize_entries(entries)
    current = list_for_event(event.uuid)
    current_keys = MapSet.new(current, &entry_key/1)
    desired_keys = MapSet.new(entries, &entry_key/1)

    added = Enum.filter(entries, &(not MapSet.member?(current_keys, entry_key(&1))))
    removed = Enum.filter(current, &(not MapSet.member?(desired_keys, entry_key(&1))))

    cond do
      not Events.can_edit?(scope, event.owner_uuid) ->
        {:error, :unauthorized}

      not Enum.all?(added, &kind_allowed?(scope, &1.kind)) ->
        {:error, :unauthorized}

      true ->
        apply_diff(scope, event, added, removed)
    end
  end

  @doc """
  Whether the scope may add participants of the given kind at all —
  drives which picker sources the UI offers (the context re-validates on
  save regardless).
  """
  @spec kind_allowed?(Scope.t() | nil, String.t()) :: boolean()
  def kind_allowed?(_scope, "free_text"), do: true
  def kind_allowed?(scope, "user"), do: Scope.can?(scope, "calendar.invite_platform_users")
  def kind_allowed?(scope, "staff_person"), do: Scope.can?(scope, "calendar.invite_staff")

  def kind_allowed?(scope, kind) when kind in ["crm_contact", "crm_company"],
    do: Scope.can?(scope, "calendar.invite_crm")

  def kind_allowed?(_scope, _kind), do: false

  # ===========================================================================

  defp apply_diff(scope, event, added, removed) do
    repo().transaction(fn ->
      if removed != [] do
        removed_uuids = Enum.map(removed, & &1.uuid)

        from(p in Participant, where: p.uuid in ^removed_uuids)
        |> repo().delete_all()
      end

      added_by = scope && Scope.user_uuid(scope)

      Enum.each(added, &insert_participant!(event, &1, added_by))

      :ok
    end)
    |> case do
      {:ok, :ok} ->
        notify_added(scope, event, added)
        {:ok, list_for_event(event.uuid)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Inserts one participant row or rolls the surrounding transaction back.
  defp insert_participant!(event, entry, added_by) do
    %Participant{}
    |> Participant.changeset(%{
      event_uuid: event.uuid,
      kind: entry.kind,
      target_uuid: entry.target_uuid,
      display_name: entry.display_name,
      added_by_uuid: added_by
    })
    |> repo().insert()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # Only newly added, directly-resolvable people are notified; skips the
  # actor adding themselves. Guarded — a logging failure never breaks the
  # save.
  defp notify_added(scope, event, added) do
    actor_uuid = scope && Scope.user_uuid(scope)

    if Code.ensure_loaded?(PhoenixKit.Activity) do
      Enum.each(added, &log_participant_added(event, &1, actor_uuid))
    end
  rescue
    _ -> :ok
  end

  defp log_participant_added(event, entry, actor_uuid) do
    target = Sources.resolve_user(entry)

    if is_binary(target) and target != actor_uuid do
      PhoenixKit.Activity.log(%{
        action: "calendar_event.participant_added",
        module: "calendar",
        mode: "manual",
        actor_uuid: actor_uuid,
        resource_type: "calendar_event",
        resource_uuid: event.uuid,
        target_uuid: target,
        metadata: %{
          "title" => event.title,
          "notification_text" => notification_text(event)
        }
      })
    end
  end

  defp notification_text(event) do
    Gettext.gettext(PhoenixKitWeb.Gettext, "You were added to the event \"%{title}\"",
      title: event.title
    )
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.map(fn entry ->
      %{
        kind: to_string(entry[:kind] || entry["kind"] || ""),
        target_uuid: entry[:target_uuid] || entry["target_uuid"],
        display_name: String.trim(to_string(entry[:display_name] || entry["display_name"] || ""))
      }
    end)
    |> Enum.filter(&(&1.kind in Participant.kinds() and &1.display_name != ""))
    |> Enum.uniq_by(&entry_key/1)
  end

  # free_text rows key on the lowercased name (mirrors the partial unique);
  # targeted rows key on kind+target.
  defp entry_key(%{kind: "free_text", display_name: name}),
    do: {"free_text", String.downcase(name)}

  defp entry_key(%{kind: kind, target_uuid: target}), do: {kind, to_string(target)}

  defp repo, do: RepoHelper.repo()
end
