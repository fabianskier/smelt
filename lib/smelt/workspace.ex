defmodule Smelt.Workspace do
  @moduledoc """
  An isolated working directory for one task of a change: a git worktree on
  its own branch, created from a base branch and kept outside the project's
  checkout, so an agent can work on the task without touching the user's
  files or any other task.

  A workspace is identified by a repository, a change name and a task id.
  Its branch, directory and metadata file are derived from those three values
  alone, so a workspace can be found again without a database:

    * branch: `smelt/<change>/<task-id>`
    * directory: `<root>/<repo-name>-<hash>/<change>/<task-id>`
    * metadata: `<root>/<repo-name>-<hash>/<change>/<task-id>.json`

  `<hash>` is the first 8 hex characters of the SHA-256 of the repository's
  absolute path, so two repositories with the same name never share a
  directory. See `default_root/0` for `<root>`.
  """

  @enforce_keys [:repo, :change, :task_id, :path, :branch, :base, :base_sha]
  defstruct @enforce_keys

  @typedoc """
  * `:repo` - absolute top-level path of the project's main checkout
  * `:change` - OpenSpec change name, kebab-case (`add-patients`)
  * `:task_id` - task id from `tasks.md` (`2.1`)
  * `:path` - absolute path of the workspace directory
  * `:branch` - the task's branch (`smelt/add-patients/2.1`)
  * `:base` - the base branch it was created from (`main`)
  * `:base_sha` - the commit `base` pointed to when it was created
  """
  @type t :: %__MODULE__{
          repo: Path.t(),
          change: String.t(),
          task_id: String.t(),
          path: Path.t(),
          branch: String.t(),
          base: String.t(),
          base_sha: String.t()
        }

  @type identifier_error :: {:invalid_identifier, :change | :task_id}

  @branch_prefix "smelt/"
  @change_format ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @task_id_format ~r/\A[0-9]+(\.[0-9]+)*\z/

  @doc """
  Checks that `change` is kebab-case and `task_id` is dot-separated numbers.

  This runs before any git command or file operation: together with the
  repository hash, it keeps every workspace path inside the root and every
  branch name a valid git ref.

      iex> Smelt.Workspace.validate_identifiers("add-patients", "2.1")
      :ok
      iex> Smelt.Workspace.validate_identifiers("../escape", "2.1")
      {:error, {:invalid_identifier, :change}}
      iex> Smelt.Workspace.validate_identifiers("add-patients", "1..2")
      {:error, {:invalid_identifier, :task_id}}
  """
  @spec validate_identifiers(term(), term()) :: :ok | {:error, identifier_error()}
  def validate_identifiers(change, task_id) do
    cond do
      not matches?(@change_format, change) -> {:error, {:invalid_identifier, :change}}
      not matches?(@task_id_format, task_id) -> {:error, {:invalid_identifier, :task_id}}
      true -> :ok
    end
  end

  defp matches?(format, value), do: is_binary(value) and Regex.match?(format, value)

  @doc """
  Returns the branch name for a task.

      iex> Smelt.Workspace.branch_name("add-patients", "2.1")
      "smelt/add-patients/2.1"
  """
  @spec branch_name(String.t(), String.t()) :: String.t()
  def branch_name(change, task_id), do: @branch_prefix <> change <> "/" <> task_id

  @doc """
  Returns the absolute path of a task's workspace directory.

  `repo` must be the repository's absolute top-level path, so the same
  repository always maps to the same directory.
  """
  @spec workspace_path(Path.t(), Path.t(), String.t(), String.t()) :: Path.t()
  def workspace_path(root, repo, change, task_id) do
    Path.join([repo_dir(root, repo), change, task_id])
  end

  @doc """
  Returns the absolute path of a task's metadata file, a sibling of its
  workspace directory, so neither the agent nor the gate sees it.
  """
  @spec metadata_path(Path.t(), Path.t(), String.t(), String.t()) :: Path.t()
  def metadata_path(root, repo, change, task_id) do
    workspace_path(root, repo, change, task_id) <> ".json"
  end

  @doc """
  Returns the directory that holds all workspaces of `repo` under `root`:
  `<root>/<repo-name>-<hash>`.
  """
  @spec repo_dir(Path.t(), Path.t()) :: Path.t()
  def repo_dir(root, repo) do
    hash = :crypto.hash(:sha256, repo) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(Path.expand(root), "#{Path.basename(repo)}-#{hash}")
  end

  @doc """
  Returns the root directory for workspaces when no `:root` option is given.

  In order: `config :smelt, Smelt.Workspace, root: ...`, then
  `$XDG_DATA_HOME/smelt/worktrees` when `XDG_DATA_HOME` is an absolute path,
  then `~/.local/share/smelt/worktrees`.
  """
  @spec default_root() :: Path.t()
  def default_root do
    case Application.get_env(:smelt, __MODULE__, [])[:root] do
      nil -> Path.join(data_home(), "smelt/worktrees")
      root -> Path.expand(root)
    end
  end

  # The XDG spec says to ignore a relative XDG_DATA_HOME.
  defp data_home do
    case System.get_env("XDG_DATA_HOME") do
      "/" <> _ = dir -> dir
      _ -> Path.expand("~/.local/share")
    end
  end
end
