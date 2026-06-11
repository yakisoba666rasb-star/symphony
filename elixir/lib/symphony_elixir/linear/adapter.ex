defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @issue_team_projects_query """
  query SymphonyIssueTeamProjects($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      team {
        projects(first: $first) {
          nodes {
            id
            name
            slugId
          }
        }
      }
    }
  }
  """

  @update_project_mutation """
  mutation SymphonyUpdateIssueProject($issueId: String!, $projectId: String!) {
    issueUpdate(id: $issueId, input: {projectId: $projectId}) {
      success
    }
  }
  """

  @github_issue_attachment_query """
  query SymphonyGitHubIssueAttachment($url: String!, $first: Int!) {
    attachmentsForURL(url: $url, first: $first, includeArchived: true) {
      nodes {
        id
        url
        issue {
          id
          identifier
        }
      }
    }
  }
  """

  @github_issue_description_query """
  query SymphonyGitHubIssueByDescription($url: String!, $first: Int!) {
    issues(filter: {description: {contains: $url}}, first: $first, includeArchived: true) {
      nodes {
        id
        identifier
        url
        description
      }
    }
  }
  """

  @github_intake_target_query """
  query SymphonyGitHubIntakeTarget($teamKey: String!, $stateName: String!, $first: Int!) {
    teams(filter: {key: {eq: $teamKey}}, first: 1) {
      nodes {
        id
        key
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
            name
          }
        }
        projects(first: $first) {
          nodes {
            id
            name
            slugId
          }
        }
      }
    }
  }
  """

  @team_projects_query """
  query SymphonyTeamProjects($teamKey: String!, $first: Int!) {
    teams(filter: {key: {eq: $teamKey}}, first: 1) {
      nodes {
        projects(first: $first) {
          nodes {
            id
            name
            slugId
            description
            url
            externalLinks(first: 20) {
              nodes {
                url
              }
            }
          }
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateGitHubBacklogIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        url
      }
    }
  }
  """

  @create_attachment_mutation """
  mutation SymphonyCreateGitHubIssueAttachment($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) {
      success
      attachment {
        id
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @zero_touch_evidence_query """
  query SymphonyZeroTouchEvidence($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      id
      identifier
      createdAt
      updatedAt
      attachments(first: $first) {
        nodes {
          id
          title
          url
          sourceType
          createdAt
        }
      }
      history(first: $first) {
        nodes {
          createdAt
          actor {
            id
            name
          }
          fromState {
            name
          }
          toState {
            name
          }
        }
      }
      comments(first: $first) {
        nodes {
          id
          body
          createdAt
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec fetch_zero_touch_evidence(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_zero_touch_evidence(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- client_module().graphql(@zero_touch_evidence_query, %{issueId: issue_id, first: 100}),
         %{} = issue <- get_in(response, ["data", "issue"]) do
      {:ok,
       %{
         issue: issue,
         attachments: get_in(issue, ["attachments", "nodes"]) || [],
         history: get_in(issue, ["history", "nodes"]) || [],
         comments: get_in(issue, ["comments", "nodes"]) || []
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :zero_touch_evidence_issue_not_found}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec fetch_issue_team_projects(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_team_projects(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- client_module().graphql(@issue_team_projects_query, %{issueId: issue_id, first: 250}),
         projects when is_list(projects) <-
           get_in(response, ["data", "issue", "team", "projects", "nodes"]) do
      {:ok, projects}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_team_projects_not_found}
    end
  end

  @spec fetch_team_projects(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_team_projects(team_key) when is_binary(team_key) do
    fetch_team_projects_with_query(@team_projects_query, team_key)
  end

  @spec update_issue_project(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_project(issue_id, project_id)
      when is_binary(issue_id) and is_binary(project_id) do
    with {:ok, response} <-
           client_module().graphql(@update_project_mutation, %{issueId: issue_id, projectId: project_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_project_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_project_update_failed}
    end
  end

  @spec github_issue_synced?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def github_issue_synced?(url) when is_binary(url) do
    with {:ok, response} <- client_module().graphql(@github_issue_attachment_query, %{url: url, first: 10}),
         attachments when is_list(attachments) <-
           get_in(response, ["data", "attachmentsForURL", "nodes"]) do
      {:ok, Enum.any?(attachments, &attachment_issue_id?/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_attachment_lookup_failed}
    end
  end

  @spec find_github_issue_by_description(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_github_issue_by_description(url) when is_binary(url) do
    with {:ok, response} <- client_module().graphql(@github_issue_description_query, %{url: url, first: 10}),
         issues when is_list(issues) <- get_in(response, ["data", "issues", "nodes"]) do
      unique_github_issue_description_match(issues, url)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_description_lookup_failed}
    end
  end

  @spec resolve_github_intake_target(String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def resolve_github_intake_target(team_key, state_name, project_aliases)
      when is_binary(team_key) and is_binary(state_name) and is_list(project_aliases) do
    with {:ok, response} <-
           client_module().graphql(@github_intake_target_query, %{
             teamKey: team_key,
             stateName: state_name,
             first: 250
           }),
         {:ok, team} <- extract_single_team(response),
         state_id when is_binary(state_id) <- get_in(team, ["states", "nodes", Access.at(0), "id"]),
         projects when is_list(projects) <- get_in(team, ["projects", "nodes"]),
         {:ok, project, source} <- unique_project_match(projects, project_aliases),
         project_id when is_binary(project_id) <- project_value(project, "id") do
      {:ok, %{team_id: team["id"], state_id: state_id, project_id: project_id, project_source: source}}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :github_intake_target_not_found}
      _ -> {:error, :github_intake_target_not_found}
    end
  end

  @spec create_github_backlog_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_github_backlog_issue(%{} = attrs) do
    input =
      %{
        teamId: Map.get(attrs, :team_id),
        stateId: Map.get(attrs, :state_id),
        projectId: Map.get(attrs, :project_id),
        title: Map.get(attrs, :title),
        description: Map.get(attrs, :description)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, response} <- client_module().graphql(@create_issue_mutation, %{input: input}),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{} = issue <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, issue}
    else
      false -> {:error, :github_backlog_issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_backlog_issue_create_failed}
    end
  end

  @spec create_issue_attachment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_issue_attachment(issue_id, title, url)
      when is_binary(issue_id) and is_binary(title) and is_binary(url) do
    input = %{issueId: issue_id, title: title, url: url}

    with {:ok, response} <- client_module().graphql(@create_attachment_mutation, %{input: input}),
         true <- get_in(response, ["data", "attachmentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_attachment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_attachment_create_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp fetch_team_projects_with_query(query, team_key) do
    with {:ok, response} <- client_module().graphql(query, %{teamKey: team_key, first: 250}),
         projects when is_list(projects) <-
           get_in(response, ["data", "teams", "nodes", Access.at(0), "projects", "nodes"]) do
      {:ok, projects}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :team_projects_not_found}
    end
  end

  defp attachment_issue_id?(%{"issue" => %{"id" => issue_id}}) when is_binary(issue_id), do: true
  defp attachment_issue_id?(_attachment), do: false

  defp issue_id?(%{"id" => issue_id}) when is_binary(issue_id), do: true
  defp issue_id?(_issue), do: false

  defp unique_github_issue_description_match(issues, url) when is_list(issues) and is_binary(url) do
    matches =
      Enum.filter(issues, fn issue ->
        issue_id?(issue) and github_issue_description_matches?(issue, url)
      end)

    case matches do
      [] -> {:ok, nil}
      [issue] -> {:ok, issue}
      issues -> {:error, {:ambiguous_github_issue_description_match, Enum.map(issues, &issue_label/1)}}
    end
  end

  defp github_issue_description_matches?(%{"description" => description}, url) when is_binary(description) do
    Regex.match?(~r/(^|[^A-Za-z0-9])#{Regex.escape(url)}([^A-Za-z0-9]|$)/i, description)
  end

  defp github_issue_description_matches?(_issue, _url), do: false

  defp issue_label(issue) when is_map(issue) do
    %{
      id: project_value(issue, "id"),
      identifier: project_value(issue, "identifier"),
      url: project_value(issue, "url")
    }
  end

  defp extract_single_team(response) do
    case get_in(response, ["data", "teams", "nodes"]) do
      [%{} = team] -> {:ok, team}
      [] -> {:error, :github_intake_team_not_found}
      teams when is_list(teams) -> {:error, {:github_intake_ambiguous_team, length(teams)}}
      _ -> {:error, :github_intake_team_not_found}
    end
  end

  defp unique_project_match(projects, aliases) do
    alias_tokens =
      aliases
      |> Enum.map(&route_token/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    matches =
      projects
      |> Enum.filter(fn project ->
        project
        |> project_tokens()
        |> Enum.any?(&(&1 in alias_tokens))
      end)

    case matches do
      [project] -> {:ok, project, matching_project_source(project, aliases)}
      [] -> {:error, :no_project_match}
      projects -> {:error, {:ambiguous_project_match, Enum.map(projects, &project_label/1)}}
    end
  end

  defp matching_project_source(project, aliases) do
    project_token_set = MapSet.new(project_tokens(project))

    aliases
    |> Enum.find(fn alias -> MapSet.member?(project_token_set, route_token(alias)) end)
    |> case do
      nil -> "unknown"
      alias -> alias
    end
  end

  defp project_tokens(project) when is_map(project) do
    [project_value(project, "name"), project_value(project, "slugId"), project_value(project, "slug_id")]
    |> Enum.map(&route_token/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp project_tokens(_project), do: []

  defp project_label(project) when is_map(project) do
    %{
      id: project_value(project, "id"),
      name: project_value(project, "name"),
      slugId: project_value(project, "slugId")
    }
  end

  defp project_value(project, key) when is_map(project) and is_binary(key) do
    Map.get(project, key) || Map.get(project, String.to_atom(key))
  end

  defp project_value(_project, _key), do: nil

  defp route_token(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp route_token(_value), do: ""

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
