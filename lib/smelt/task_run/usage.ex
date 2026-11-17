defmodule Smelt.TaskRun.Usage do
  @moduledoc """
  What a task run's agent consumed, collected from its runner events: tokens,
  turns, cost and model, and its tool calls grouped by tool.

  `record/2` takes the `Smelt.Runner.Event`s of every attempt in order;
  `lines/1` renders the report the terminal shows, and `entry/2` with
  `append/2` keep one JSON line per task run in `usage.jsonl`.

  The CLI reports no tokens per tool, so a tool's share of the context is
  approximated by the characters its results returned to the agent. Nothing
  here keeps prompts, tool inputs or tool outputs: only names and counts.
  """

  alias Smelt.Runner.Event
  alias Smelt.Runner.Result

  @token_kinds [:input, :cache_creation, :cache_read, :output]

  defstruct model: nil,
            turns: 0,
            cost_usd: 0.0,
            tokens: %{input: 0, cache_creation: 0, cache_read: 0, output: 0},
            tools: %{},
            pending: %{}

  @type tool :: %{calls: non_neg_integer(), output_chars: non_neg_integer()}

  @type t :: %__MODULE__{
          model: String.t() | nil,
          turns: non_neg_integer(),
          cost_usd: float(),
          tokens: %{atom() => non_neg_integer()},
          tools: %{String.t() => tool()},
          pending: %{String.t() => String.t()}
        }

  @doc "An empty usage."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Adds one runner event. Events that carry no usage leave it unchanged.

  A `:result` event adds its tokens, turns and cost, so the attempts of a
  task are summed.
  """
  @spec record(t(), Event.t()) :: t()
  def record(%__MODULE__{} = usage, %Event{type: :session_started, data: %{model: model}})
      when is_binary(model) do
    %{usage | model: model}
  end

  def record(%__MODULE__{} = usage, %Event{type: :tool_use, data: %{id: id, name: name}})
      when is_binary(name) do
    tools = Map.update(usage.tools, name, %{calls: 1, output_chars: 0}, &add(&1, :calls, 1))
    %{usage | tools: tools, pending: Map.put(usage.pending, id, name)}
  end

  def record(%__MODULE__{} = usage, %Event{type: :tool_result, data: data}) do
    case Map.pop(usage.pending, data[:tool_use_id]) do
      {nil, _pending} ->
        usage

      {name, pending} ->
        tools = Map.update!(usage.tools, name, &add(&1, :output_chars, size(data[:content])))
        %{usage | tools: tools, pending: pending}
    end
  end

  def record(%__MODULE__{} = usage, %Event{type: :result, data: %{result: %Result{} = result}}) do
    tokens =
      Map.new(@token_kinds, fn kind ->
        {kind, usage.tokens[kind] + (result.usage[kind] || 0)}
      end)

    %{
      usage
      | tokens: tokens,
        turns: usage.turns + (result.num_turns || 0),
        cost_usd: usage.cost_usd + (result.cost_usd || 0.0)
    }
  end

  def record(%__MODULE__{} = usage, %Event{}), do: usage

  @doc "The tools called, with their calls and output size, largest output first."
  @spec tools(t()) :: [
          %{name: String.t(), calls: non_neg_integer(), output_chars: non_neg_integer()}
        ]
  def tools(%__MODULE__{tools: tools}) do
    tools
    |> Enum.map(fn {name, tool} -> Map.put(tool, :name, name) end)
    |> Enum.sort_by(&{-&1.output_chars, -&1.calls, &1.name})
  end

  @doc "The lines of the report shown when a task run ends."
  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{} = usage) do
    tokens = usage.tokens

    header =
      "Token use: #{usage.turns} turns, $#{:erlang.float_to_binary(usage.cost_usd / 1, decimals: 2)}" <>
        if(usage.model, do: ", #{usage.model}", else: "")

    counts =
      "  input #{number(tokens.input)} · cache write #{number(tokens.cache_creation)} · " <>
        "cache read #{number(tokens.cache_read)} · output #{number(tokens.output)}"

    [header, counts | tool_lines(tools(usage))]
  end

  defp tool_lines([]), do: []

  defp tool_lines(tools) do
    width = tools |> Enum.map(&String.length(&1.name)) |> Enum.max()

    rows =
      for tool <- tools do
        "    #{String.pad_trailing(tool.name, width)}  " <>
          "#{String.pad_leading(Integer.to_string(tool.calls), 3)} calls  " <>
          "#{String.pad_leading(number(tool.output_chars), 9)} chars"
      end

    ["  Tool output returned to the agent:" | rows]
  end

  @doc """
  The record of a task run for `usage.jsonl`. `run` gives the `:repo`,
  `:change`, `:task_id` and `:status` of the run.
  """
  @spec entry(t(), map()) :: map()
  def entry(%__MODULE__{} = usage, run) do
    %{
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      repo: run.repo,
      change: run.change,
      task_id: run.task_id,
      status: to_string(run.status),
      model: usage.model,
      turns: usage.turns,
      cost_usd: usage.cost_usd,
      tokens: usage.tokens,
      tools: tools(usage)
    }
  end

  @doc "Appends `entry` as one JSON line to the file at `path`, creating it if needed."
  @spec append(Path.t(), map()) :: :ok | {:error, File.posix()}
  def append(path, entry) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, [JSON.encode!(entry), "\n"], [:append])
    end
  end

  defp add(tool, key, n), do: Map.update!(tool, key, &(&1 + n))

  # A tool result is a string or a list of content blocks; only text counts.
  defp size(content) when is_binary(content), do: String.length(content)

  defp size(content) when is_list(content) do
    content |> Enum.map(&block_size/1) |> Enum.sum()
  end

  defp size(_other), do: 0

  defp block_size(%{"text" => text}) when is_binary(text), do: String.length(text)
  defp block_size(_other), do: 0

  # 1234567 -> "1,234,567"
  defp number(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
