defmodule Smelt.GitRepo do
  @moduledoc """
  Helpers to build throwaway git repositories in tests.

  Every function raises when git fails, so a broken fixture fails the test at
  the line that built it. Git runs without the developer's global or system
  config, and commits use a fixed identity with signing disabled, so a global
  `commit.gpgsign` or hook can't break the suite.

  Smelt's own `Smelt.Git` is deliberately not used here: these helpers build
  the fixtures that `Smelt.Git` is tested against.
  """

  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"LC_ALL", "C"}
  ]

  @identity [
    "-c",
    "user.name=Smelt Test",
    "-c",
    "user.email=test@smelt.invalid",
    "-c",
    "commit.gpgsign=false"
  ]

  @doc """
  Creates a repository in `dir` with one commit (a `README.md`) on `main`.

  Returns the repository's real path (symlinks resolved, so on macOS
  `/var/...` becomes `/private/var/...`), which is what git reports.
  """
  @spec init!(Path.t()) :: Path.t()
  def init!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    commit!(dir, "initial commit", %{"README.md" => "# Test repo\n"})
    realpath!(dir)
  end

  @doc """
  Writes `files` (a map of relative path to content), stages everything and
  commits it with `message`. With no files, it makes an empty commit.

  Returns the new commit's SHA.
  """
  @spec commit!(Path.t(), String.t(), %{Path.t() => iodata()}) :: String.t()
  def commit!(repo, message, files \\ %{}) do
    Enum.each(files, fn {path, content} -> write!(repo, path, content) end)
    git!(repo, ["add", "--all"])
    git!(repo, @identity ++ ["commit", "--quiet", "--allow-empty", "-m", message])
    sha!(repo, "HEAD")
  end

  @doc "Creates `branch` at `start` without checking it out."
  @spec branch!(Path.t(), String.t(), String.t()) :: :ok
  def branch!(repo, branch, start \\ "HEAD") do
    git!(repo, ["branch", branch, start])
    :ok
  end

  @doc "Checks out an existing `branch`."
  @spec checkout!(Path.t(), String.t()) :: :ok
  def checkout!(repo, branch) do
    git!(repo, ["checkout", "--quiet", branch])
    :ok
  end

  @doc """
  Writes a file in the working tree without staging it. Use it to make a
  tracked file modified or to add an untracked file.
  """
  @spec write!(Path.t(), Path.t(), iodata()) :: :ok
  def write!(repo, path, content) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  @doc "Returns the checked-out branch."
  @spec current_branch(Path.t()) :: String.t()
  def current_branch(repo), do: repo |> git!(["branch", "--show-current"]) |> String.trim()

  @doc "Returns the names of the local branches, sorted."
  @spec branches(Path.t()) :: [String.t()]
  def branches(repo) do
    repo
    |> git!(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
    |> String.split("\n", trim: true)
  end

  @doc "Returns `git status --porcelain` output (empty for a clean checkout)."
  @spec status(Path.t()) :: String.t()
  def status(repo), do: git!(repo, ["status", "--porcelain"])

  @doc "Returns the full SHA that `rev` points to."
  @spec sha!(Path.t(), String.t()) :: String.t()
  def sha!(repo, rev),
    do: repo |> git!(["rev-parse", "--verify", rev <> "^{commit}"]) |> String.trim()

  @doc "Returns `path` with symlinks resolved."
  @spec realpath!(Path.t()) :: Path.t()
  def realpath!(path) do
    {resolved, 0} = System.cmd("realpath", [path])
    String.trim(resolved)
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true, env: @env) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} exited with #{status}:\n#{output}"
    end
  end
end
