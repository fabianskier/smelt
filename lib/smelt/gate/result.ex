defmodule Smelt.Gate.Result do
  @moduledoc """
  The outcome of `Smelt.Gate.run/2`.

    * `:status` - `:pass`, or `:fail` when any rule failed
    * `:rules` - one outcome per rule, always in this order: `:protected_files`,
      `:diff_size`, `:openspec`, `:checks`. Each is
      `%{name: name, status: :pass | :fail | :skipped, details: map}`
    * `:duration_ms` - how long the gate took
  """

  @enforce_keys [:status, :rules, :duration_ms]
  defstruct @enforce_keys

  @type rule :: %{name: atom(), status: :pass | :fail | :skipped, details: map()}
  @type t :: %__MODULE__{status: :pass | :fail, rules: [rule()], duration_ms: non_neg_integer()}

  @doc "Returns the outcome of the rule called `name`."
  @spec rule(t(), atom()) :: rule() | nil
  def rule(%__MODULE__{rules: rules}, name), do: Enum.find(rules, &(&1.name == name))
end
