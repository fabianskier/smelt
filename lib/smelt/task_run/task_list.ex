defmodule Smelt.TaskRun.TaskList do
  @moduledoc """
  Reads a task from an OpenSpec change's `tasks.md` at a given commit.

  Tasks are checkbox lines such as `- [ ] 2.1 Implement the thing`. As in
  OpenSpec, a box holding only `x` (any case, any spacing) is done; any other
  marker is unfinished.
  """

  alias Smelt.Git

  @type task :: %{id: String.t(), description: String.t()}

  @line ~r/^\s*-\s+\[([^\]]*)\]\s+(\S+)\s+(.+?)\s*$/

  @doc "Path of a change's `tasks.md`, relative to the project root."
  @spec path(String.t()) :: String.t()
  def path(change), do: "openspec/changes/#{change}/tasks.md"

  @doc """
  Returns the open task `task_id` of `change` as it is at `sha` in `repo`.

  Errors: `:change_not_found` (no `tasks.md` for the change at that commit),
  `:task_not_found` and `:task_done`.
  """
  @spec fetch(Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, task()} | {:error, :change_not_found | :task_not_found | :task_done}
  def fetch(repo, sha, change, task_id) do
    case Git.cmd(repo, ["show", "#{sha}:#{path(change)}"]) do
      {:ok, contents} -> find(contents, task_id)
      {:error, _} -> {:error, :change_not_found}
    end
  end

  @doc """
  Finds `task_id` in the contents of a `tasks.md`.

      iex> Smelt.TaskRun.TaskList.find("- [ ] 1.1 Do it\\n- [x] 1.2 Done\\n", "1.1")
      {:ok, %{id: "1.1", description: "Do it"}}
      iex> Smelt.TaskRun.TaskList.find("- [x] 1.2 Done\\n", "1.2")
      {:error, :task_done}
  """
  @spec find(String.t(), String.t()) :: {:ok, task()} | {:error, :task_not_found | :task_done}
  def find(contents, task_id) do
    contents
    |> String.split("\n")
    |> Enum.find_value({:error, :task_not_found}, fn line ->
      case Regex.run(@line, line, capture: :all_but_first) do
        [box, ^task_id, description] ->
          if String.trim(box) in ["x", "X"],
            do: {:error, :task_done},
            else: {:ok, %{id: task_id, description: description}}

        _ ->
          nil
      end
    end)
  end
end
