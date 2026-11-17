defmodule Smelt.Runner do
  @moduledoc """
  The contract for running a coding agent, plus helpers to follow a run.

  Every implementation (Claude Code today; others later) runs an agent with a
  prompt, broadcasts `Smelt.Runner.Event`s on the run's PubSub topic while it
  works, and returns the final result.

  To follow a run, pick its id first and subscribe before starting it, since
  PubSub does not replay past messages:

      run_id = Smelt.Runner.new_run_id()
      :ok = Smelt.Runner.subscribe(run_id)
      {:ok, result} = SomeRunner.run(prompt, cwd: dir, run_id: run_id)

  Subscribers receive `{Smelt.Runner, run_id, %Smelt.Runner.Event{}}` messages.
  """

  alias Smelt.Runner.{Event, Result}

  @pubsub Smelt.PubSub
  @registry Smelt.Runner.Registry

  @typedoc "Why a run ended without a result."
  @type error ::
          {:exit_status, non_neg_integer(), output :: [String.t()]}
          | {:agent_error, term()}
          | {:usage_limit, Result.t()}
          | :no_result
          | :executable_not_found
          | :stopped
          | {:crashed, term()}

  @doc """
  Runs an agent with `prompt` and blocks until it finishes.

  Options:

    * `:cwd` (required) - working directory of the agent
    * `:run_id` - id of the run; generated when absent
    * `:args` - extra arguments for the agent
    * `:env` - extra environment variables for the agent process
  """
  @callback run(prompt :: String.t(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, error()}

  @doc "Returns a new unique run id."
  @spec new_run_id() :: String.t()
  def new_run_id, do: Ecto.UUID.generate()

  @doc "Returns the PubSub topic of a run."
  @spec topic(String.t()) :: String.t()
  def topic(run_id) when is_binary(run_id), do: "run:" <> run_id

  @doc "Subscribes the calling process to the events of a run."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(run_id))

  @doc """
  Stops a running run and terminates its agent process.

  The run then ends with `{:error, :stopped}`. Returns `{:error, :not_found}`
  when no run with that id is running.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> GenServer.call(pid, :stop)
      [] -> {:error, :not_found}
    end
  catch
    # The run ended between the lookup and the call.
    :exit, _reason -> {:error, :not_found}
  end

  @doc "Broadcasts an event of a run to its subscribers."
  @spec broadcast(String.t(), Event.t()) :: :ok | {:error, term()}
  def broadcast(run_id, %Event{} = event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(run_id), {__MODULE__, run_id, event})
  end
end
