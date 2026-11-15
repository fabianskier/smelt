defmodule Smelt.Gate.Config do
  @moduledoc """
  A project's gate settings, read from `.smelt/gate.json` at a task's base
  commit, so a task can't change the limits it is checked against.

  Every setting is optional:

      {
        "test_paths": ["test/"],
        "max_changed_lines": 400,
        "max_changed_files": 20,
        "timeout_seconds": 900
      }

  A path is under a test path when it starts with it: `test/` matches
  `test/a_test.exs` but not `tests/a.exs`.
  """

  alias Smelt.Git

  @path ".smelt/gate.json"

  defstruct test_paths: ["test/"],
            max_changed_lines: 400,
            max_changed_files: 20,
            timeout_seconds: 900

  @type t :: %__MODULE__{
          test_paths: [String.t()],
          max_changed_lines: pos_integer(),
          max_changed_files: pos_integer(),
          timeout_seconds: pos_integer()
        }

  @keys %{
    "test_paths" => :test_paths,
    "max_changed_lines" => :max_changed_lines,
    "max_changed_files" => :max_changed_files,
    "timeout_seconds" => :timeout_seconds
  }

  @doc "Path of the configuration file, relative to the project root."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Loads the configuration as it was at `base_sha` in `repo`.

  Returns the defaults when the file doesn't exist at that commit, and
  `{:error, {:invalid_config, message}}` when it isn't valid.
  """
  @spec load(Path.t(), String.t()) ::
          {:ok, t()} | {:error, {:invalid_config, String.t()} | Git.error()}
  def load(repo, base_sha) do
    object = "#{base_sha}:#{@path}"

    case Git.cmd(repo, ["cat-file", "-e", object]) do
      {:error, _} ->
        {:ok, %__MODULE__{}}

      {:ok, _} ->
        with {:ok, json} <- Git.cmd(repo, ["show", object]) do
          parse(json)
        end
    end
  end

  @doc """
  Parses and validates the contents of a configuration file.

      iex> Smelt.Gate.Config.parse(~s({"max_changed_lines": 100}))
      {:ok, %Smelt.Gate.Config{max_changed_lines: 100}}
      iex> Smelt.Gate.Config.parse(~s({"max_lines": 100}))
      {:error, {:invalid_config, ~s(unknown setting "max_lines")}}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_config, String.t()}}
  def parse(json) do
    case JSON.decode(json) do
      {:ok, settings} when is_map(settings) ->
        Enum.reduce_while(settings, {:ok, %__MODULE__{}}, fn {key, value}, {:ok, config} ->
          case put(config, key, value) do
            {:ok, config} -> {:cont, {:ok, config}}
            {:error, message} -> {:halt, {:error, {:invalid_config, message}}}
          end
        end)

      {:ok, _} ->
        {:error, {:invalid_config, "#{@path} must contain a JSON object"}}

      {:error, _} ->
        {:error, {:invalid_config, "#{@path} is not valid JSON"}}
    end
  end

  defp put(config, key, value) do
    case Map.fetch(@keys, key) do
      {:ok, field} ->
        if valid?(field, value),
          do: {:ok, Map.put(config, field, value)},
          else: {:error, "#{inspect(key)} #{expected(field)}"}

      :error ->
        {:error, "unknown setting #{inspect(key)}"}
    end
  end

  defp valid?(:test_paths, paths) do
    is_list(paths) and paths != [] and Enum.all?(paths, &(is_binary(&1) and &1 != ""))
  end

  defp valid?(_number, value), do: is_integer(value) and value > 0

  defp expected(:test_paths), do: "must be a non-empty list of non-empty strings"
  defp expected(_number), do: "must be a positive integer"
end
