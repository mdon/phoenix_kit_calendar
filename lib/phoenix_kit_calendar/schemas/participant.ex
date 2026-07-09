defmodule PhoenixKitCalendar.Schemas.Participant do
  @moduledoc """
  A participant attached to a calendar event.

  Loose `kind` + `target_uuid` reference (activity-feed pattern — no
  cross-module FKs) with a `display_name` snapshot frozen at save, so the
  row renders even if the source module is later disabled or the record
  deleted.

  | kind | target_uuid | grants visibility to |
  |------|-------------|----------------------|
  | `user` | a `phoenix_kit_users` uuid | that user |
  | `staff_person` | a `phoenix_kit_staff_people` uuid | the person's linked user (live) |
  | `crm_contact` | a `phoenix_kit_crm_contacts` uuid | the contact's linked user, when any (live) |
  | `crm_company` | a `phoenix_kit_crm_companies` uuid | every CURRENT member contact's linked user (live) |
  | `free_text` | NULL | nobody — display only |

  Visibility resolution is LIVE: `PhoenixKitCalendar.Events` joins the
  physical staff/CRM tables at query time (they exist in every install via
  core migrations; module code is never needed and empty tables no-op).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(user staff_person crm_contact crm_company free_text)

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_calendar_event_participants" do
    field(:event_uuid, UUIDv7)
    field(:kind, :string)
    field(:target_uuid, UUIDv7)
    field(:display_name, :string)
    field(:added_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc "Allowed participant kinds."
  def kinds, do: @kinds

  @doc false
  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:event_uuid, :kind, :target_uuid, :display_name, :added_by_uuid])
    |> validate_required([:event_uuid, :kind, :display_name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:display_name, max: 255)
    |> validate_shape()
    |> unique_constraint([:event_uuid, :kind, :target_uuid],
      name: :idx_calendar_participants_target,
      message: "is already a participant"
    )
    |> unique_constraint([:event_uuid, :display_name],
      name: :idx_calendar_participants_free_text,
      message: "is already a participant"
    )
    |> check_constraint(:kind, name: :calendar_participant_kind)
    |> check_constraint(:target_uuid, name: :calendar_participant_shape)
  end

  # Mirrors the DB CHECK: free_text has no target; every other kind must.
  defp validate_shape(changeset) do
    kind = get_field(changeset, :kind)
    target = get_field(changeset, :target_uuid)

    cond do
      kind == "free_text" and not is_nil(target) ->
        add_error(changeset, :target_uuid, "free-text participants take no target")

      kind != "free_text" and kind in @kinds and is_nil(target) ->
        add_error(changeset, :target_uuid, "is required for this participant kind")

      true ->
        changeset
    end
  end
end
