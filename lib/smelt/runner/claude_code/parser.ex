defmodule Smelt.Runner.ClaudeCode.Parser do
  @moduledoc """
  Translates Claude Code's stream-json output into `Smelt.Runner.Event`s.

  Pure functions only: no processes, no I/O. Each output line of
  `claude -p --output-format stream-json --verbose` is one JSON object; a line
  maps to zero or more events (an assistant message can hold several blocks,
  and a rate-limit line reports several windows).

  Unknown event types produce no events, so newer CLI versions do not break runs.
  """

  alias Smelt.Runner.{Event, Result}

  @doc """
  Decodes and parses one output line.

  Returns `{:error, :invalid_json}` for lines that are not a JSON object, so the
  caller can keep them as plain output (for example, messages printed to stderr).
  """
  @spec parse_line(String.t()) :: {:ok, [Event.t()]} | {:error, :invalid_json}
  def parse_line(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, %{} = decoded} -> {:ok, parse(decoded)}
      _ -> {:error, :invalid_json}
    end
  end

  @doc "Parses one decoded stream-json object into events."
  @spec parse(map()) :: [Event.t()]
  def parse(%{"type" => "system", "subtype" => "init"} = msg) do
    [
      event(:session_started, %{
        session_id: msg["session_id"],
        model: msg["model"],
        cwd: msg["cwd"]
      })
    ]
  end

  def parse(%{"type" => "assistant", "message" => %{"content" => content}})
      when is_list(content) do
    Enum.flat_map(content, &assistant_block/1)
  end

  def parse(%{"type" => "user", "message" => %{"content" => content}}) when is_list(content) do
    Enum.flat_map(content, &user_block/1)
  end

  def parse(%{"type" => "rate_limit_event", "rate_limit_info" => info}) when is_map(info) do
    info |> rate_limit_windows() |> Enum.map(&event(:rate_limit, &1))
  end

  def parse(%{"type" => "result"} = msg) do
    [
      event(:result, %{
        is_error: Map.get(msg, "is_error", false),
        subtype: msg["subtype"],
        api_error_status: msg["api_error_status"],
        result: to_result(msg)
      })
    ]
  end

  def parse(_unknown), do: []

  @doc "Builds a `Smelt.Runner.Result` from a decoded `result` object."
  @spec to_result(map()) :: Result.t()
  def to_result(msg) do
    %Result{
      text: msg["result"] || "",
      cost_usd: msg["total_cost_usd"],
      usage: usage(msg["usage"]),
      num_turns: msg["num_turns"],
      duration_ms: msg["duration_ms"],
      session_id: msg["session_id"]
    }
  end

  defp assistant_block(%{"type" => "text", "text" => text}), do: [event(:text, %{text: text})]

  defp assistant_block(%{"type" => "tool_use"} = block) do
    [event(:tool_use, %{id: block["id"], name: block["name"], input: block["input"]})]
  end

  defp assistant_block(_other), do: []

  defp user_block(%{"type" => "tool_result"} = block) do
    [
      event(:tool_result, %{
        tool_use_id: block["tool_use_id"],
        content: block["content"],
        is_error: Map.get(block, "is_error", false)
      })
    ]
  end

  defp user_block(_other), do: []

  # Newer CLIs report every window under "unifiedWindows"; older ones only the
  # window that triggered the event.
  defp rate_limit_windows(%{"unifiedWindows" => windows})
       when is_map(windows) and windows != %{} do
    for {window, data} <- Enum.sort(windows) do
      rate_limit(window, data["utilization"], data["resetsAt"], data["status"])
    end
  end

  defp rate_limit_windows(info) do
    [rate_limit(info["rateLimitType"], info["utilization"], info["resetsAt"], info["status"])]
  end

  # Window names stay strings: they come from an external program, and atoms are
  # never created from external input.
  defp rate_limit(window, utilization, resets_at, status) do
    %{window: window, utilization: utilization, resets_at: to_datetime(resets_at), status: status}
  end

  defp to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  defp to_datetime(_), do: nil

  defp usage(%{} = usage) do
    %{
      input: usage["input_tokens"],
      output: usage["output_tokens"],
      cache_read: usage["cache_read_input_tokens"],
      cache_creation: usage["cache_creation_input_tokens"]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp usage(_), do: %{}

  defp event(type, data), do: %Event{type: type, data: data}
end
