defmodule PhoenixKitCalendar.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitCalendar.Web.CalendarLiveTest do
        use PhoenixKitCalendar.LiveCase

        test "renders the calendar page", %{conn: conn} do
          conn = put_test_scope(conn, fake_scope(permissions: ["calendar"]))
          {:ok, _view, html} = live(conn, "/en/admin/calendar")
          assert html =~ "My calendar"
        end
      end

  ## Scope assigns

  The calendar LiveView reads `socket.assigns[:phoenix_kit_current_scope]`
  to authorize everything (own calendar vs `calendar.view_others` /
  `calendar.edit_others`). Tests plug a fake scope via
  `put_test_scope/2` + `fake_scope/1`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitCalendar.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitCalendar.ActivityLogAssertions
      import PhoenixKitCalendar.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitCalendar.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  The calendar LiveView and Events context call `Scope.can?/2` and
  `Scope.user_uuid/1` — both pattern-match on
  `%PhoenixKit.Users.Auth.Scope{}` (with a real `%User{}` inside), so a
  plain map won't satisfy them. `:cached_permissions` is the MapSet
  `can?/2` checks membership on (plus live module enablement).

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4 (good enough for tests)
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role atoms; `[:owner]` makes `admin?/1` true
    * `:permissions` — list of module-key strings; `["calendar"]`
      grants the demo button
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope(permissions: ["calendar"]))
      {:ok, _view, html} = live(conn, "/en/admin/calendar")
      assert html =~ "My calendar"
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["User"])
    permissions = Keyword.get(opts, :permissions, ["calendar"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    # A real %User{} struct (not a bare map): Scope.user_uuid/1 and friends
    # pattern-match on it. cached_roles is a LIST of role-name strings,
    # mirroring what Scope.for_user/1 builds in production.
    user = %PhoenixKit.Users.Auth.User{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the test
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/calendar")
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
