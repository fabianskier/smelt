# Smelt's own gate checks, run by Smelt.Gate with /bin/sh from a task
# workspace (a fresh worktree: no deps or build yet).
set -eu

export MIX_ENV=test

mix deps.get
mix deps.unlock --check-unused
mix compile --warnings-as-errors
mix format --check-formatted
mix test
