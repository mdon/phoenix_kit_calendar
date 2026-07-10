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

  ## Leak hygiene (quorum-hardened; browse mode added on the boss's call)

  Searches cap results per source, return only `{kind, target uuid,
  display name}` — no phones or profile data beyond the label — and
  exclude soft-deleted rows (`status = 'trashed'`). An EMPTY query is
  "browse mode": the first page (same per-source cap) of each source the
  scope may search, so clicking the picker offers people before any
  typing. That exposes nothing a permitted search couldn't already
  enumerate — the per-source invite permissions remain the gate. A user's label falls back to their email when
  no name is set, matching how users are identified everywhere else in
  the admin (the person panel, the users list); pickers therefore expose
  emails exactly as far as the rest of the admin already does.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  @per_source_cap 8

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
  `{[{source, [%{kind, target_uuid, display_name}]}], has_more?}` in
  source order. An empty query lists each source's first page (browse
  mode — the picker opens on click with people already offered); `limit`
  is the per-source page size and grows with the picker's "Load more".

  ## Deduplication

  The same human often exists as a platform user AND a staff person AND
  a CRM contact (linked via `user_uuid`). Rows resolving to a user
  already listed by an earlier source are dropped — source order wins,
  so the `user` kind (the most direct visibility/notification link)
  shadows its staff/CRM mirrors, and a staff row shadows a CRM contact
  linking the same account. Rows with no user link are always kept.
  """
  @spec search_participants(Scope.t() | nil, String.t(), pos_integer()) ::
          {[{atom(), [map()]}], boolean()}
  def search_participants(scope, query, limit \\ @per_source_cap) do
    query = String.trim(query)

    per_source =
      scope
      |> available_participant_sources()
      # one extra row per source so "has more" is knowable
      |> Enum.map(fn source -> {source, search_source(source, query, limit + 1)} end)
      |> dedupe_linked_users()

    has_more? = Enum.any?(per_source, fn {_source, results} -> length(results) > limit end)

    results =
      per_source
      |> Enum.map(fn {source, results} ->
        {source, results |> Enum.take(limit) |> Enum.map(&Map.delete(&1, :user_uuid))}
      end)
      |> Enum.reject(fn {_source, results} -> results == [] end)

    {results, has_more?}
  end

  # Drops rows whose linked platform user was already emitted by an
  # earlier source (or an earlier row of the same source).
  defp dedupe_linked_users(per_source) do
    {deduped, _seen} =
      Enum.map_reduce(per_source, MapSet.new(), fn {source, results}, seen ->
        {kept, seen} =
          Enum.map_reduce(results, seen, fn entry, seen ->
            case entry[:user_uuid] do
              nil ->
                {entry, seen}

              uuid ->
                if MapSet.member?(seen, uuid),
                  do: {nil, seen},
                  else: {entry, MapSet.put(seen, uuid)}
            end
          end)

        {{source, Enum.reject(kept, &is_nil/1)}, seen}
      end)

    deduped
  end

  defp search_source(:users, query, limit) do
    pattern = like_pattern(query)

    from(u in "phoenix_kit_users",
      where: u.is_active == true,
      where:
        ilike(u.email, ^pattern) or
          ilike(fragment("COALESCE(?, '')", u.first_name), ^pattern) or
          ilike(fragment("COALESCE(?, '')", u.last_name), ^pattern),
      order_by: [asc: u.email],
      limit: ^limit,
      select: %{
        uuid: type(u.uuid, UUIDv7),
        email: u.email,
        first_name: u.first_name,
        last_name: u.last_name
      }
    )
    |> repo().all()
    |> Enum.map(fn u ->
      %{kind: "user", target_uuid: u.uuid, display_name: user_label(u), user_uuid: u.uuid}
    end)
  rescue
    _ -> []
  end

  defp search_source(:staff, query, limit) do
    pattern = like_pattern(query)

    from(sp in "phoenix_kit_staff_people",
      where: sp.status != "trashed",
      where: ilike(fragment("COALESCE(?, '')", sp.name), ^pattern),
      order_by: [asc: sp.name],
      limit: ^limit,
      select: %{uuid: type(sp.uuid, UUIDv7), name: sp.name, user_uuid: type(sp.user_uuid, UUIDv7)}
    )
    |> repo().all()
    |> Enum.map(fn sp ->
      %{
        kind: "staff_person",
        target_uuid: sp.uuid,
        display_name: sp.name || "",
        user_uuid: sp.user_uuid
      }
    end)
    |> Enum.reject(&(&1.display_name == ""))
  rescue
    _ -> []
  end

  defp search_source(:crm_contacts, query, limit) do
    pattern = like_pattern(query)

    from(c in "phoenix_kit_crm_contacts",
      where: c.status != "trashed",
      where: ilike(fragment("COALESCE(?, '')", c.name), ^pattern),
      order_by: [asc: c.name],
      limit: ^limit,
      select: %{uuid: type(c.uuid, UUIDv7), name: c.name, user_uuid: type(c.user_uuid, UUIDv7)}
    )
    |> repo().all()
    |> Enum.map(fn c ->
      %{
        kind: "crm_contact",
        target_uuid: c.uuid,
        display_name: c.name || "",
        user_uuid: c.user_uuid
      }
    end)
    |> Enum.reject(&(&1.display_name == ""))
  rescue
    _ -> []
  end

  defp search_source(:crm_companies, query, limit) do
    pattern = like_pattern(query)

    from(co in "phoenix_kit_crm_companies",
      where: co.status != "trashed",
      where: ilike(co.name, ^pattern),
      order_by: [asc: co.name],
      limit: ^limit,
      select: %{uuid: type(co.uuid, UUIDv7), name: co.name}
    )
    |> repo().all()
    |> Enum.map(fn co ->
      %{kind: "crm_company", target_uuid: co.uuid, display_name: co.name, user_uuid: nil}
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
        where: l.status != "trashed",
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
  Resolves the CANONICAL display name for a participant target from its
  source table — `{:ok, name}` or `:error` when the target doesn't exist
  (or is soft-deleted). `Participants` calls this at insert time so a
  client can never store a spoofed label or a fabricated uuid: whatever
  the picker claimed, the persisted name is what the source table says.
  """
  @spec canonical_name(String.t(), String.t()) :: {:ok, String.t()} | :error
  def canonical_name("user", target_uuid) do
    from(u in "phoenix_kit_users",
      where: u.uuid == type(^target_uuid, UUIDv7) and u.is_active == true,
      select: %{email: u.email, first_name: u.first_name, last_name: u.last_name}
    )
    |> repo().one()
    |> case do
      nil -> :error
      user -> {:ok, user_label(user)}
    end
  rescue
    _ -> :error
  end

  def canonical_name(kind, target_uuid)
      when kind in ["staff_person", "crm_contact", "crm_company"] do
    {table, _} = kind_table(kind)

    from(r in table,
      where: r.uuid == type(^target_uuid, UUIDv7) and r.status != "trashed",
      select: r.name
    )
    |> repo().one()
    |> case do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def canonical_name(_kind, _target), do: :error

  defp kind_table("staff_person"), do: {"phoenix_kit_staff_people", :name}
  defp kind_table("crm_contact"), do: {"phoenix_kit_crm_contacts", :name}
  defp kind_table("crm_company"), do: {"phoenix_kit_crm_companies", :name}

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
