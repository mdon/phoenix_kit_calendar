# Test helper for PhoenixKitCalendar test suite.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable (`:integration` tag).
#
# To enable integration tests:
#
#     mix test.setup           # createdb + migrate
#     mix test
#
# The test endpoint runs with `server: false` (no port opened); LiveView
# tests drive it via `Phoenix.LiveViewTest.live/2` only.

# Elixir 1.19's `mix test` no longer auto-loads modules from the
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Our
# support modules are compiled but not loaded, so explicit
# `Code.require_file/2` calls are needed before this file references
# them.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_calendar, PhoenixKitCalendar.Test.Repo)[:database] ||
    "phoenix_kit_calendar_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` not installed in PATH — fall through to the connect path,
    # which will fail gracefully and exclude :integration tests.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitCalendar.Test.Repo.start_link()

      # Build the schema by running core's versioned migrations directly.
      # The previous hand-rolled `test/support/postgres/migrations/` shim
      # recreated `phoenix_kit_settings`, `phoenix_kit_activities`, and
      # the `uuid_generate_v7()` function — all owned by core's V03 /
      # V40 / V90 migrations. Schema drift impossible by construction.
      PhoenixKit.Migration.ensure_current(PhoenixKitCalendar.Test.Repo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitCalendar.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_calendar, :test_repo_available, repo_available)

# Start minimal PhoenixKit services so the module's runtime dependencies
# (PubSub topics, ModuleRegistry) resolve during tests.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
# Rate limiter backend — Auth.register_user/2 (used by test fixtures) hits it.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to an empty string for tests so
# `Paths.index()` etc. produce paths the test router can match. Admin
# paths always get the default locale ("en") prefix, so our router
# scope is `/en/admin/calendar`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our
# LiveViews via `live/2` with real URLs. Runs with `server: false`, so
# no port is opened. Only starts when the test DB is available —
# without DB, LiveView tests are excluded anyway and an endpoint start
# would fail on missing Phoenix/Plug deps in a DB-less smoke run.
if repo_available do
  {:ok, _} = PhoenixKitCalendar.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
