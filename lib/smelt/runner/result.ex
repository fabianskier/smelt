defmodule Smelt.Runner.Result do
  @moduledoc """
  The final result of a successful agent run, with its cost and usage.
  """

  @enforce_keys [:text]
  defstruct [:text, :cost_usd, :num_turns, :duration_ms, :session_id, usage: %{}]

  @typedoc "Token counts reported by the agent."
  @type usage :: %{
          optional(:input) => non_neg_integer(),
          optional(:output) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:cache_creation) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          text: String.t(),
          cost_usd: float() | nil,
          usage: usage(),
          num_turns: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          session_id: String.t() | nil
        }
end
