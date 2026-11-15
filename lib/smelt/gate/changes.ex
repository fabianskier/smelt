defmodule Smelt.Gate.Changes do
  @moduledoc """
  Measures a workspace's changes since its base commit: committed,
  uncommitted and untracked files, honoring the project's `.gitignore`.

  Git's real index is never touched. The working tree is staged into a
  throwaway index file outside the repository and diffed from there:

      GIT_INDEX_FILE=<tmp> git read-tree HEAD
      GIT_INDEX_FILE=<tmp> git add --all
      GIT_INDEX_FILE=<tmp> git diff --cached --no-renames <base_sha>

  Renames are reported as a deletion plus an addition, so a renamed file is
  always seen as removed from its old path.
  """

  alias Smelt.Git
  alias Smelt.Workspace

  @type change :: %{
          path: String.t(),
          change: :added | :modified | :deleted | :type_changed,
          added: non_neg_integer(),
          deleted: non_neg_integer()
        }

  @doc """
  Returns the workspace's changed files, sorted by path. Binary files count
  zero lines.

  Options:

    * `:tmp_dir` - where the temporary index file is created, default
      `System.tmp_dir!/0`
  """
  @spec measure(Workspace.t(), keyword()) :: {:ok, [change()]} | {:error, Git.error()}
  def measure(%Workspace{} = ws, opts \\ []) do
    index =
      Path.join(
        Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0),
        "smelt-gate-index-#{System.unique_integer([:positive])}"
      )

    env = [env: [{"GIT_INDEX_FILE", index}]]
    diff = ["diff", "--cached", "--no-renames", "-z"]

    try do
      with {:ok, _} <- Git.cmd(ws.path, ["read-tree", "HEAD"], env),
           {:ok, _} <- Git.cmd(ws.path, ["add", "--all"], env),
           {:ok, names} <- Git.cmd(ws.path, diff ++ ["--name-status", ws.base_sha], env),
           {:ok, counts} <- Git.cmd(ws.path, diff ++ ["--numstat", ws.base_sha], env) do
        {:ok, merge(parse_name_status(names), parse_numstat(counts))}
      end
    after
      File.rm(index)
    end
  end

  # `--name-status -z` prints `<status>\0<path>\0` for each file.
  defp parse_name_status(output) do
    output
    |> String.split("\0", trim: true)
    |> Enum.chunk_every(2)
    |> Map.new(fn [status, path] -> {path, change_type(status)} end)
  end

  defp change_type("A"), do: :added
  defp change_type("D"), do: :deleted
  defp change_type("T"), do: :type_changed
  defp change_type(_modified), do: :modified

  # `--numstat -z` prints `<added>\t<deleted>\t<path>\0`, with `-` for both
  # counts of a binary file.
  defp parse_numstat(output) do
    output
    |> String.split("\0", trim: true)
    |> Map.new(fn line ->
      [added, deleted, path] = String.split(line, "\t", parts: 3)
      {path, {count(added), count(deleted)}}
    end)
  end

  defp count("-"), do: 0
  defp count(n), do: String.to_integer(n)

  defp merge(types, counts) do
    types
    |> Enum.map(fn {path, type} ->
      {added, deleted} = Map.get(counts, path, {0, 0})
      %{path: path, change: type, added: added, deleted: deleted}
    end)
    |> Enum.sort_by(& &1.path)
  end
end
