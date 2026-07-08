defmodule PhoenixKitCalendar.Schemas.Event do
  @moduledoc """
  A calendar event on a user's personal calendar.

  ## Time model

  Mirrors `phoenix_live_calendar` (and iCal RFC 5545): ends are EXCLUSIVE
  (`[start, end)`).

  - Timed events (`all_day: false`) use `starts_at`/`ends_at` (UTC).
  - All-day events (`all_day: true`) use `starts_on`/`ends_on` (dates) —
    proper date semantics, no UTC-midnight ambiguity. A single-day
    all-day event on July 10 stores `starts_on: 2026-07-10,
    ends_on: 2026-07-11`.

  The changeset nils out the inactive pair when `all_day` flips, so form
  toggling never trips the DB CHECK (`calendar_event_time_shape`).

  ## Ownership

  `owner_uuid` is deliberately NOT castable — it is set once by
  `PhoenixKitCalendar.Events.create_event/4` from an explicitly
  authorized argument and is immutable afterwards. Accepting it from
  form params would let any calendar user create events on someone
  else's calendar or move events between calendars.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(confirmed cancelled)

  # daisyUI background classes phoenix_live_calendar can infer a readable
  # text color for (Safe.infer_text_color/1). Stored verbatim; nil renders
  # the lib default. A whitelist — never accept arbitrary CSS classes.
  @colors ~w(bg-primary bg-secondary bg-accent bg-info bg-success bg-warning bg-error bg-neutral)

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_calendar_events" do
    field(:owner_uuid, UUIDv7)
    field(:title, :string)
    field(:description, :string)
    field(:location, :string)
    field(:all_day, :boolean, default: false)
    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)
    field(:starts_on, :date)
    field(:ends_on, :date)
    field(:color, :string)
    field(:status, :string, default: "confirmed")

    timestamps(type: :utc_datetime)
  end

  @doc "Allowed status values."
  def statuses, do: @statuses

  @doc "Allowed color classes (daisyUI backgrounds the calendar can style)."
  def colors, do: @colors

  @doc """
  Changeset for create/update. `owner_uuid` is not castable — see the
  moduledoc.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :title,
      :description,
      :location,
      :all_day,
      :starts_at,
      :ends_at,
      :starts_on,
      :ends_on,
      :color,
      :status
    ])
    |> validate_required([:title])
    |> validate_length(:title, max: 255)
    |> validate_length(:location, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:color, @colors)
    |> validate_time_shape()
    |> check_constraint(:all_day,
      name: :calendar_event_time_shape,
      message: "event times don't match the all-day flag"
    )
    |> check_constraint(:status, name: :calendar_event_status)
  end

  # Enforces the same shape as the DB CHECK, with friendlier ergonomics:
  # the pair that doesn't match `all_day` is cleared rather than rejected,
  # so a form toggling the flag doesn't have to blank four fields itself.
  defp validate_time_shape(changeset) do
    if get_field(changeset, :all_day) do
      changeset
      |> put_change(:starts_at, nil)
      |> put_change(:ends_at, nil)
      |> validate_required([:starts_on, :ends_on],
        message: "is required for all-day events"
      )
      |> validate_end_after_start(:starts_on, :ends_on, &Date.compare/2)
    else
      changeset
      |> put_change(:starts_on, nil)
      |> put_change(:ends_on, nil)
      |> validate_required([:starts_at, :ends_at],
        message: "is required for timed events"
      )
      |> validate_end_after_start(:starts_at, :ends_at, &DateTime.compare/2)
    end
  end

  defp validate_end_after_start(changeset, start_field, end_field, compare) do
    start_value = get_field(changeset, start_field)
    end_value = get_field(changeset, end_field)

    if start_value && end_value && compare.(end_value, start_value) != :gt do
      add_error(changeset, end_field, "must be after the start")
    else
      changeset
    end
  end
end
