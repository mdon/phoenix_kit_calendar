defmodule PhoenixKitCalendar.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_calendar"

  def project do
    [
      app: :phoenix_kit_calendar,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Calendar module for PhoenixKit — personal calendars per user with " <>
          "fine-grained view/edit permissions for other users' calendars",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitCalendar",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so LiveCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitCalendar.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitCalendar.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar. Unset => the published
  # pin, so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings, auth Scope, and
      # the V141 calendar-events migration. Sub-permissions (Scope.can?/2)
      # and the events table ship in the release after 1.7.179 — until then
      # the standalone suite is red against the published pin; develop with
      # PHOENIX_KIT_PATH=../phoenix_kit.
      pk_dep(:phoenix_kit, "~> 1.7.179"),

      # The server-rendered calendar component (month view etc.).
      pk_dep(:phoenix_live_calendar, "~> 0.2"),

      # LiveView is needed for the admin page.
      {:phoenix_live_view, "~> 1.1"},

      # Optional: add ex_doc for generating documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # HTML parser for Phoenix.LiveViewTest in LiveView tests
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitCalendar",
      source_ref: "v#{@version}"
    ]
  end
end
