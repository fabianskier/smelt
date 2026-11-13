defmodule Smelt.Repo do
  use Ecto.Repo,
    otp_app: :smelt,
    adapter: Ecto.Adapters.Postgres
end
