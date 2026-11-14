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

  @type create_error ::
          identifier_error()
          | :not_a_repository
          | {:unknown_base, String.t()}
          | :already_exists
          | {:metadata, File.posix()}
          | Smelt.Git.error()

  @type fetch_error :: identifier_error() | :not_a_repository | :not_found

  alias Smelt.Git

  @branch_prefix "smelt/"
  @default_base "main"

  @doc """
  Creates the workspace for a task: a new branch `smelt/<change>/<task-id>`
  starting at the base branch's current commit, checked out into the task's
  directory, plus its metadata file.

  `repo` may be any path inside the project repository, or inside one of its
  worktrees: the workspace always belongs to the main checkout.

  Options:

    * `:base` - the branch (or any commit-ish) to start from, default `"main"`
    * `:root` - the workspaces root, default `default_root/0`

  Errors:

    * `{:invalid_identifier, :change | :task_id}` - see `validate_identifiers/2`
    * `:not_a_repository` - `repo` is not inside a git repository
    * `{:unknown_base, base}` - the base does not name a commit
    * `:already_exists` - the task's branch or directory already exists
    * `{:metadata, posix}` - the metadata file could not be written
    * `{:git, args, status, output}` - any other git failure

  On any error after the worktree was added, the worktree, branch and
  metadata file are removed again, so nothing is left behind.
  """
  @spec create(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, create_error()}
  def create(repo, change, task_id, opts \\ []) do
    base = Keyword.get(opts, :base, @default_base)
    root = root(opts)

    with :ok <- validate_identifiers(change, task_id),
         {:ok, repo} <- main_checkout(repo),
         {:ok, base_sha} <- resolve_base(repo, base) do
      ws = %__MODULE__{
        repo: repo,
        change: change,
        task_id: task_id,
        path: workspace_path(root, repo, change, task_id),
        branch: branch_name(change, task_id),
        base: base,
        base_sha: base_sha
      }

      with :ok <- ensure_absent(ws),
           {:ok, _} <- add_worktree(ws) do
        case write_metadata(ws, metadata_path(root, repo, change, task_id)) do
          :ok -> {:ok, ws}
          {:error, _} = error -> rollback(ws, root, error)
        end
      end
    end
  end

  @doc """
  Returns the workspace of a task created earlier with `create/4`.

  A workspace exists only when git lists a worktree on the task's branch and
  its metadata file is present; otherwise this returns `{:error, :not_found}`.
  Accepts the `:root` option, like `create/4`.
  """
  @spec fetch(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, fetch_error()}
  def fetch(repo, change, task_id, opts \\ []) do
    root = root(opts)

    with :ok <- validate_identifiers(change, task_id),
         {:ok, repo} <- main_checkout(repo) do
      branch = branch_name(change, task_id)

      with true <- worktree_on_branch?(repo, branch),
           {:ok, meta} <- read_metadata(metadata_path(root, repo, change, task_id)) do
        {:ok,
         %__MODULE__{
           repo: repo,
           change: change,
           task_id: task_id,
           path: workspace_path(root, repo, change, task_id),
           branch: branch,
           base: meta["base"],
           base_sha: meta["base_sha"]
         }}
      else
        _ -> {:error, :not_found}
      end
    end
  end

  defp root(opts), do: opts |> Keyword.get_lazy(:root, &default_root/0) |> Path.expand()

  # The main checkout is the parent of the common git directory, which is the
  # same for the repository and all of its worktrees.
  defp main_checkout(path) do
    case Git.cmd(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, common_dir} -> {:ok, common_dir |> String.trim() |> Path.dirname()}
      {:error, _} -> {:error, :not_a_repository}
    end
  end

  defp resolve_base(repo, base) do
    args = ["rev-parse", "--verify", "--quiet", "--end-of-options", base <> "^{commit}"]

    case Git.cmd(repo, args) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, _} -> {:error, {:unknown_base, base}}
    end
  end

  defp ensure_absent(ws) do
    if branch_exists?(ws.repo, ws.branch) or File.exists?(ws.path) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp branch_exists?(repo, branch) do
    match?({:ok, _}, Git.cmd(repo, ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch]))
  end

  defp add_worktree(ws) do
    Git.cmd(ws.repo, ["worktree", "add", "--quiet", "-b", ws.branch, ws.path, ws.base_sha])
  end

  defp write_metadata(ws, path) do
    json = JSON.encode!(%{"repo" => ws.repo, "base" => ws.base, "base_sha" => ws.base_sha})

    case File.write(path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:metadata, reason}}
    end
  end

  defp read_metadata(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"base" => base, "base_sha" => sha} = meta}
         when is_binary(base) and is_binary(sha) <- JSON.decode(json) do
      {:ok, meta}
    end
  end

  # Undo a partial create. Each step is best effort: the original error is
  # what the caller needs to see.
  defp rollback(ws, root, error) do
    _ = Git.cmd(ws.repo, ["worktree", "remove", "--force", ws.path])
    _ = Git.cmd(ws.repo, ["branch", "-D", ws.branch])
    _ = File.rm(metadata_path(root, ws.repo, ws.change, ws.task_id))
    error
  end

  defp worktree_on_branch?(repo, branch) do
    case Git.cmd(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} -> String.contains?(output, "\nbranch refs/heads/#{branch}\n")
      {:error, _} -> false
    end
  end

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
