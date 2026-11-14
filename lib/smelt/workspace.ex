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
         {:ok, repo} <- main_checkout(repo) do
      with_repo_lock(repo, fn -> do_create(repo, change, task_id, base, root) end)
    end
  end

  defp do_create(repo, change, task_id, base, root) do
    with {:ok, base_sha} <- resolve_base(repo, base) do
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

      with {:ok, worktrees} <- worktrees(repo),
           true <- Map.has_key?(worktrees, branch),
           {:ok, ws} <- load(root, repo, change, task_id) do
        {:ok, ws}
      else
        _ -> {:error, :not_found}
      end
    end
  end

  @doc """
  Lists the workspaces Smelt manages in `repo`, sorted by change and task id.

  Only worktrees on a `smelt/<change>/<task-id>` branch that have a metadata
  file are included, so worktrees and branches the user created by hand are
  never listed. Accepts the `:root` option, like `create/4`.
  """
  @spec list(Path.t(), keyword()) ::
          {:ok, [t()]} | {:error, :not_a_repository | Smelt.Git.error()}
  def list(repo, opts \\ []) do
    root = root(opts)

    with {:ok, repo} <- main_checkout(repo),
         {:ok, worktrees} <- worktrees(repo) do
      workspaces =
        for branch <- Map.keys(worktrees),
            {change, task_id} <- parse_branch(branch),
            {:ok, ws} <- [load(root, repo, change, task_id)] do
          ws
        end

      {:ok, Enum.sort_by(workspaces, &{&1.change, task_id_sort_key(&1.task_id)})}
    end
  end

  @doc """
  Removes a task's workspace: its directory (including uncommitted and
  untracked files), its metadata file and, when its work is safe to drop,
  its branch.

  The branch is deleted when it has no commits that are not in the base
  branch, or when `force: true` is given. Otherwise it is kept, so finished
  but unmerged work is never lost, and the result says so.

  Returns:

    * `{:ok, :removed}` - everything is gone
    * `{:ok, :branch_kept}` - the directory is gone, the unmerged branch stays
    * `{:ok, :absent}` - there was nothing to remove

  Accepts the `:root` and `:force` (default `false`) options. A directory
  deleted by hand is handled: git's stale record of it is pruned.
  """
  @spec remove(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, :removed | :branch_kept | :absent}
          | {:error, identifier_error() | :not_a_repository | Smelt.Git.error()}
  def remove(repo, change, task_id, opts \\ []) do
    root = root(opts)
    force? = Keyword.get(opts, :force, false)

    with :ok <- validate_identifiers(change, task_id),
         {:ok, repo} <- main_checkout(repo) do
      with_repo_lock(repo, fn -> do_remove(repo, change, task_id, root, force?) end)
    end
  end

  defp do_remove(repo, change, task_id, root, force?) do
    with {:ok, worktrees} <- worktrees(repo) do
      path = workspace_path(root, repo, change, task_id)
      meta_path = metadata_path(root, repo, change, task_id)
      branch = branch_name(change, task_id)

      meta =
        case read_metadata(meta_path) do
          {:ok, meta} -> meta
          {:error, _} -> nil
        end

      found? =
        Map.has_key?(worktrees, branch) or branch_exists?(repo, branch) or
          File.exists?(path) or File.exists?(meta_path)

      with :ok <- remove_worktree(repo, Map.get(worktrees, branch), path),
           {:ok, branch_result} <- remove_branch(repo, branch, meta, force?) do
        _ = File.rm(meta_path)

        cond do
          not found? -> {:ok, :absent}
          branch_result == :kept -> {:ok, :branch_kept}
          true -> {:ok, :removed}
        end
      end
    end
  end

  # A registered worktree is removed by git; `--force` because a workspace
  # normally has untracked build output. If its directory was deleted by hand,
  # git only needs to forget it. A leftover directory git doesn't know about
  # is deleted directly: its path is derived from validated identifiers, so it
  # is always inside the workspaces root.
  defp remove_worktree(repo, registered_path, path) do
    result =
      cond do
        registered_path && File.dir?(registered_path) ->
          Git.cmd(repo, ["worktree", "remove", "--force", registered_path])

        registered_path ->
          Git.cmd(repo, ["worktree", "prune"])

        true ->
          {:ok, ""}
      end

    with {:ok, _} <- result do
      _ = File.rm_rf(path)
      :ok
    end
  end

  # `git branch -d` is not used: it checks the branch against the main
  # checkout's HEAD, not against the workspace's base.
  defp remove_branch(repo, branch, meta, force?) do
    cond do
      not branch_exists?(repo, branch) ->
        {:ok, :none}

      force? or merged?(repo, branch, meta) ->
        with {:ok, _} <- Git.cmd(repo, ["branch", "-D", branch]), do: {:ok, :deleted}

      true ->
        {:ok, :kept}
    end
  end

  # Without metadata the base is unknown, so the branch is treated as unmerged.
  defp merged?(_repo, _branch, nil), do: false

  defp merged?(repo, branch, %{"base" => base}) do
    match?({:ok, _}, Git.cmd(repo, ["merge-base", "--is-ancestor", branch, base]))
  end

  defp load(root, repo, change, task_id) do
    with {:ok, meta} <- read_metadata(metadata_path(root, repo, change, task_id)) do
      {:ok,
       %__MODULE__{
         repo: repo,
         change: change,
         task_id: task_id,
         path: workspace_path(root, repo, change, task_id),
         branch: branch_name(change, task_id),
         base: meta["base"],
         base_sha: meta["base_sha"]
       }}
    end
  end

  # Returns the change and task id encoded in a managed branch name, as a
  # list so it can be used as a comprehension generator.
  defp parse_branch(@branch_prefix <> rest) do
    with [change, task_id] <- String.split(rest, "/"),
         :ok <- validate_identifiers(change, task_id) do
      [{change, task_id}]
    else
      _ -> []
    end
  end

  defp parse_branch(_branch), do: []

  defp task_id_sort_key(task_id) do
    task_id |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

  # `create` and `remove` check the repository's state and then change it.
  # Serializing them per repository makes that check-then-act atomic, so each
  # call behaves as if it ran alone: two creations of the same task give one
  # workspace and one `:already_exists`, never a raw git error. `fetch` and
  # `list` only read and don't take the lock. The lock is held for the
  # duration of a few git commands.
  defp with_repo_lock(repo, fun) do
    :global.trans({{__MODULE__, repo}, self()}, fun, [node()])
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

  # Returns the repository's worktrees that are on a branch, as a map of
  # branch name to worktree path. Git allows a branch in only one worktree.
  #
  # `git worktree list --porcelain` prints one block per worktree, separated
  # by blank lines:
  #
  #     worktree /path/to/worktree
  #     HEAD <sha>
  #     branch refs/heads/<branch>
  defp worktrees(repo) do
    with {:ok, output} <- Git.cmd(repo, ["worktree", "list", "--porcelain"]) do
      worktrees =
        for block <- String.split(output, "\n\n", trim: true),
            lines = String.split(block, "\n", trim: true),
            "worktree " <> path <- Enum.take(lines, 1),
            "branch refs/heads/" <> branch <- lines,
            into: %{} do
          {branch, path}
        end

      {:ok, worktrees}
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
