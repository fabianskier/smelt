defmodule Smelt.Runner.Event do
  @moduledoc """
  A provider-independent event emitted while an agent runs.

  Runners translate each provider's wire format (for example Claude Code's
  stream-json) into these events, so subscribers never depend on a provider.

  Types:

    * `:session_started` - the agent session started (`data`: session id, model, cwd)
    * `:text` - the agent wrote text (`data`: `%{text: ...}`)
    * `:tool_use` - the agent called a tool (`data`: id, name, input)
    * `:tool_result` - a tool returned (`data`: tool use id, content, error flag)
    * `:rate_limit` - usage-limit status for one window (`data`: window, utilization, resets at)
    * `:result` - the agent reported its final result (`data`: a `Smelt.Runner.Result`)
    * `:finished` - the run ended; always the last event (`data`: `{:ok, result}` or `{:error, reason}`)
  """

  @enforce_keys [:type, :data]
  defstruct [:type, :data]

  @type type ::
          :session_started
          | :text
          | :tool_use
          | :tool_result
          | :rate_limit
          | :result
          | :finished

  @type t :: %__MODULE__{type: type(), data: term()}
end
