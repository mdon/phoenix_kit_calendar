defmodule PhoenixKitCalendar.Sources do
  @moduledoc """
  Search facade over the participant/location sources the event form can
  draw from — platform users (core), staff people, CRM contacts, CRM
  companies, and stored locations.

  ## Standalone by construction

  Every query here is SCHEMALESS against the physical tables, which exist
  in every install (they ship as core versioned migrations) — no sibling
  module's code is ever required, and an unused module's empty tables
  simply return nothing. A source is OFFERED only when its module is
  enabled (`Permissions.feature_enabled?/1`, which is false when the
  module code is absent) AND the viewer holds the matching invite
  sub-permission — the permission composes with enablement, it never
  substitutes for it.

  ## Leak hygiene (quorum-hardened)

  Searches require a minimum of #{2} characters, cap results per source,
  return only `{kind, target uuid, display name}` — never emails, phones,
  or profile data beyond the label — and exclude soft-deleted rows
  (`status = 'trashed'`).
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  @min_query_len 2
  @per_source_cap 8

  @doc "Minimum characters before a search runs."
  def min_query_len, do: @min_query_len

  @doc """
  Which participant sources this scope may search. Order = display order.
  """
  @spec available_participant_sources(Scope.t() | nil) :: [atom()]
  def available_participant_sources(scope) do
    [
      {:users, Scope.can?(scope, "calendar.invite_platform_users")},
      {:staff, Scope.can?(scope, "calendar.invite_staff") and feature_on?("staff")},
      {:crm_contacts, Scope.can?(scope, "calendar.invite_crm") and feature_on?("crm")},
      {:crm_companies, Scope.can?(scope, "calendar.invite_crm") and feature_on?("crm")}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Whether the locations module is available for the location picker."
  @spec locations_available?() :: boolean()
  def locations_available?, do: feature_on?("locations")

  @doc """
  Searches every source the scope may use. Returns
  `%{source => [%{kind, target_uuid, display_name}]}` in source order —
  empty map for queries under the minimum length.
  """
  @spec search_participants(Scope.t() | nil, String.t()) :: [{atom(), [map()]}]
  def search_participants(scope, query) do
    query = String.trim(query)

    if String.length(query) < @min_query_len do
      []
    else
      scope
      |> available_participant_sources()
      |> Enum.map(fn source -> {source, search_source(source, query)} end)
      |> Enum.reject(fn {_source, results} -> results == [] end)
    end
  end

  defp search_source(:users, query) do
    pattern = like_pattern(query)

    from(u in "phoenix_kit_users",
      where: u.is_active == true,
      where:
        ilike(u.email, ^pattern) or
          ilike(fragment("COALESCE(?, '')", u.first_name), ^pattern) or
          ilike(fragment("COALESCE(?, '')", u.last_name), ^pattern),
      order_by: [asc: u.email],
      limit: @per_source_cap,
      select: %{
        uuid: type(u.uuid, UUIDv7),
        email: u.email,
        first_name: u.first_name,
        last_name: u.last_name
      }
    )
    |> repo().all()
    |> Enum.map(fn u ->
      %{kind: "user", target_uuid: u.uuid, display_name: user_label(u)}
    end)
  rescue
    _ -> []
  end

  defp search_source(:staff, query) do
    pattern = like_pattern(query)

    from(sp in "phoenix_kit_staff_people",
      where: sp.status != "trashed",
      where:
        ilike(fragment("COALESCE(?, '')", sp.first_name), ^pattern) or
          ilike(fragment("COALESCE(?, '')", sp.last_name), ^pattern),
      order_by: [asc: sp.last_name],
      limit: @per_source_cap,
      select: %{
        uuid: type(sp.uuid, UUIDv7),
        first_name: sp.first_name,
        last_name: sp.last_name
      }
    )
    |> repo().all()
    |> Enum.map(fn sp ->
      %{
        kind: "staff_person",
        target_uuid: sp.uuid,
        display_name: String.trim("#{sp.first_name || ""} #{sp.last_name || ""}")
      }
    end)
  rescue
    _ -> []
  end

  defp search_source(:crm_contacts, query) do
    pattern = like_pattern(query)

    from(c in "phoenix_kit_crm_contacts",
      where: c.status != "trashed",
      where:
        ilike(fragment("COALESCE(?, '')", c.first_name), ^pattern) or
          ilike(fragment("COALESCE(?, '')", c.last_name), ^pattern),
      order_by: [asc: c.last_name],
      limit: @per_source_cap,
      select: %{
        uuid: type(c.uuid, UUIDv7),
        first_name: c.first_name,
        last_name: c.last_name
      }
    )
    |> repo().all()
    |> Enum.map(fn c ->
      %{
        kind: "crm_contact",
        target_uuid: c.uuid,
        display_name: String.trim("#{c.first_name || ""} #{c.last_name || ""}")
      }
    end)
  rescue
    _ -> []
  end

  defp search_source(:crm_companies, query) do
    pattern = like_pattern(query)

    from(co in "phoenix_kit_crm_companies",
      where: co.status != "trashed",
      where: ilike(co.name, ^pattern),
      order_by: [asc: co.name],
      limit: @per_source_cap,
      select: %{uuid: type(co.uuid, UUIDv7), name: co.name}
    )
    |> repo().all()
    |> Enum.map(fn co ->
      %{kind: "crm_company", target_uuid: co.uuid, display_name: co.name}
    end)
  rescue
    _ -> []
  end

  @doc """
  Stored locations for the form's datalist suggestions (name-ordered,
  capped). Empty when the locations module is unavailable.
  """
  @spec list_locations() :: [%{uuid: String.t(), name: String.t()}]
  def list_locations do
    if locations_available?() do
      from(l in "phoenix_kit_locations",
        order_by: [asc: l.name],
        limit: 100,
        select: %{uuid: type(l.uuid, UUIDv7), name: l.name}
      )
      |> repo().all()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Live-resolves the platform user a participant entry maps to right now —
  used for add-notifications. Companies fan out to nobody (their members
  see the event via live visibility, but are not individually notified).
  """
  @spec resolve_user(map()) :: String.t() | nil
  def resolve_user(%{kind: "user", target_uuid: uuid}), do: uuid

  def resolve_user(%{kind: "staff_person", target_uuid: uuid}) do
    from(sp in "phoenix_kit_staff_people",
      where: sp.uuid == type(^uuid, UUIDv7) and sp.status != "trashed",
      select: type(sp.user_uuid, UUIDv7)
    )
    |> repo().one()
  rescue
    _ -> nil
  end

  def resolve_user(%{kind: "crm_contact", target_uuid: uuid}) do
    from(c in "phoenix_kit_crm_contacts",
      where: c.uuid == type(^uuid, UUIDv7) and c.status != "trashed",
      select: type(c.user_uuid, UUIDv7)
    )
    |> repo().one()
  rescue
    _ -> nil
  end

  def resolve_user(_), do: nil

  defp user_label(%{first_name: first, last_name: last, email: email}) do
    case String.trim("#{first || ""} #{last || ""}") do
      "" -> email
      name -> name
    end
  end

  defp like_pattern(query) do
    "%" <> String.replace(query, ["%", "_"], fn c -> "\\" <> c end) <> "%"
  end

  defp feature_on?(key), do: Permissions.feature_enabled?(key)

  defp repo, do: RepoHelper.repo()
end
