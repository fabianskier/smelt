# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :smelt,
  ecto_repos: [Smelt.Repo],
  generators: [timestamp_type: :utc_datetime]

# Claude Code CLI used by Smelt.Runner.ClaudeCode (a name on the PATH or a path).
config :smelt, Smelt.Runner.ClaudeCode, executable: "claude"

# Background jobs. One queue per agent provider; the limit is its capacity.
config :smelt, Oban,
  engine: Oban.Engines.Basic,
  repo: Smelt.Repo,
  queues: [claude: 1, local: 1],
  plugins: [
    # Keep finished jobs for 7 days so their history can be inspected.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescue jobs left "executing" after a crash or restart.
    Oban.Plugins.Lifeline
  ]

# Configure the endpoint
config :smelt, SmeltWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SmeltWeb.ErrorHTML, json: SmeltWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Smelt.PubSub,
  live_view: [signing_salt: "IqTOlpLj"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  smelt: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  smelt: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
