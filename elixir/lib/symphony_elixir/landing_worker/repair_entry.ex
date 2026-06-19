defmodule SymphonyElixir.LandingWorker.RepairEntry do
  @moduledoc """
  Typed repair request payload handed from LandingWorker to Orchestrator.
  """

  @enforce_keys [
    :issue_id,
    :issue_identifier,
    :title,
    :repository,
    :pr_url,
    :pr_state,
    :draft,
    :mergeability,
    :head_branch,
    :head_sha,
    :repair_reason
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          issue_id: String.t(),
          issue_identifier: String.t() | nil,
          title: String.t() | nil,
          repository: String.t() | nil,
          pr_url: String.t(),
          pr_state: String.t() | nil,
          draft: boolean() | String.t() | nil,
          mergeability: String.t() | nil,
          head_branch: String.t() | nil,
          head_sha: String.t() | nil,
          repair_reason: term()
        }

  @spec new!(map(), term()) :: t()
  def new!(%{} = entry, reason) do
    %__MODULE__{
      issue_id: Map.fetch!(entry, :issue_id),
      issue_identifier: Map.get(entry, :issue_identifier),
      title: Map.get(entry, :title),
      repository: Map.get(entry, :repository),
      pr_url: Map.fetch!(entry, :pr_url),
      pr_state: Map.get(entry, :pr_state),
      draft: Map.get(entry, :draft),
      mergeability: Map.get(entry, :mergeability),
      head_branch: Map.get(entry, :head_branch),
      head_sha: Map.get(entry, :head_sha),
      repair_reason: reason
    }
  end
end
