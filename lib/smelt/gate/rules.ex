defmodule Smelt.Gate.Rules do
  @moduledoc """
  The gate's rules that only look at the measured changes. Pure functions:
  each takes the changes from `Smelt.Gate.Changes.measure/2` and the
  project's `Smelt.Gate.Config`, and returns a rule outcome.
  """

  alias Smelt.Gate.Config

  @type outcome :: %{name: atom(), status: :pass | :fail | :skipped, details: map()}

  @smelt_dir ".smelt/"

  @doc """
  Fails when a file that existed at the base commit under a test path is
  modified, deleted or renamed (a rename is a deletion), or when anything
  under `.smelt/` changes. Adding new test files is allowed.
  """
  @spec protected_files([Smelt.Gate.Changes.change()], Config.t()) :: outcome()
  def protected_files(changes, %Config{test_paths: test_paths}) do
    violations =
      for %{path: path, change: change} <- changes,
          violation?(path, change, test_paths) do
        %{path: path, change: if(change == :type_changed, do: :modified, else: change)}
      end

    %{
      name: :protected_files,
      status: if(violations == [], do: :pass, else: :fail),
      details: %{violations: violations}
    }
  end

  defp violation?(path, change, test_paths) do
    String.starts_with?(path, @smelt_dir) or
      (change != :added and String.starts_with?(path, test_paths))
  end

  @doc """
  Fails when the changed lines (added plus deleted) or the changed files
  exceed the configured maximums.
  """
  @spec diff_size([Smelt.Gate.Changes.change()], Config.t()) :: outcome()
  def diff_size(changes, %Config{} = config) do
    lines = Enum.sum_by(changes, &(&1.added + &1.deleted))
    files = length(changes)

    %{
      name: :diff_size,
      status:
        if(lines > config.max_changed_lines or files > config.max_changed_files,
          do: :fail,
          else: :pass
        ),
      details: %{
        changed_lines: lines,
        changed_files: files,
        max_changed_lines: config.max_changed_lines,
        max_changed_files: config.max_changed_files
      }
    }
  end
end
