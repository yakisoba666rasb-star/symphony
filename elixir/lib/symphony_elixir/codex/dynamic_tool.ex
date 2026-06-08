defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @superpowers_brainstorming_tool "superpowers_brainstorming"
  @superpowers_writing_plans_tool "superpowers_writing_plans"
  @legacy_superpowers_brainstorming_tool "superpowers:brainstorming"
  @legacy_superpowers_writing_plans_tool "superpowers:writing-plans"
  @allowed_linear_mutation_fields MapSet.new(["commentCreate", "commentUpdate"])
  @linear_graphql_description """
  Execute a raw read-only GraphQL query against Linear using Symphony's configured auth.
  """
  @superpowers_brainstorming_description """
  Run the Superpowers brainstorming gate for a Symphony issue before implementation.
  Returns a planning artifact that clarifies requirements, unknowns, risks, and acceptance criteria.
  """
  @superpowers_writing_plans_description """
  Run the Superpowers writing-plans gate for a Symphony issue before implementation.
  Returns a concrete implementation plan with steps, files, validation, and blockers.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Read-only GraphQL query document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @superpowers_input_schema %{
    "type" => "object",
    "additionalProperties" => true,
    "properties" => %{
      "issue_identifier" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "requirements_summary" => %{
        "type" => ["string", "array"],
        "items" => %{"type" => "string"}
      },
      "acceptance_criteria" => %{
        "type" => ["string", "array"],
        "items" => %{"type" => "string"}
      },
      "implementation_steps" => %{
        "type" => ["string", "array"],
        "items" => %{"type" => "string"}
      },
      "verification_method" => %{
        "type" => ["string", "array"],
        "items" => %{"type" => "string"}
      },
      "open_questions_or_blockers" => %{
        "type" => ["string", "array"],
        "items" => %{"type" => "string"}
      },
      "risks" => %{
        "type" => ["string", "array"],
        "items" => %{"type" => "string"}
      },
      "context" => %{"type" => "string"}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @superpowers_brainstorming_tool ->
        execute_superpowers_tool(@superpowers_brainstorming_tool, arguments)

      @legacy_superpowers_brainstorming_tool ->
        execute_superpowers_tool(@superpowers_brainstorming_tool, arguments)

      @superpowers_writing_plans_tool ->
        execute_superpowers_tool(@superpowers_writing_plans_tool, arguments)

      @legacy_superpowers_writing_plans_tool ->
        execute_superpowers_tool(@superpowers_writing_plans_tool, arguments)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @superpowers_brainstorming_tool,
        "description" => @superpowers_brainstorming_description,
        "inputSchema" => @superpowers_input_schema
      },
      %{
        "name" => @superpowers_writing_plans_tool,
        "description" => @superpowers_writing_plans_description,
        "inputSchema" => @superpowers_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- authorize_linear_graphql_query(query, opts),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_superpowers_tool(tool, arguments) do
    arguments = normalize_superpowers_arguments(arguments)

    tool
    |> superpowers_markdown(arguments)
    |> success_response()
  end

  defp normalize_superpowers_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> %{}
      context -> %{"context" => context}
    end
  end

  defp normalize_superpowers_arguments(arguments) when is_map(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_superpowers_arguments(_arguments), do: %{}

  defp superpowers_markdown(@superpowers_brainstorming_tool, arguments) do
    """
    # Superpowers Brainstorming Artifact

    #{issue_heading(arguments)}

    ## Requirements summary
    #{bullet_section(arguments, "requirements_summary", fallback_requirement(arguments))}

    ## Acceptance criteria candidates
    #{bullet_section(arguments, "acceptance_criteria", ["Define observable completion criteria before editing."])}

    ## Unknowns and risks
    #{bullet_section(arguments, "risks", ["Confirm dependencies, current branch, test scope, and automation side effects."])}

    ## Open questions or blockers
    #{bullet_section(arguments, "open_questions_or_blockers", ["None recorded by the tool caller."])}

    ## Next step
    Call `superpowers_writing_plans` with the clarified requirements before editing code.
    """
    |> String.trim()
  end

  defp superpowers_markdown(@superpowers_writing_plans_tool, arguments) do
    """
    # Superpowers Writing Plan Artifact

    #{issue_heading(arguments)}

    ## Requirements summary
    #{bullet_section(arguments, "requirements_summary", fallback_requirement(arguments))}

    ## Acceptance criteria
    #{bullet_section(arguments, "acceptance_criteria", ["The implementation satisfies the Linear issue without unrelated changes."])}

    ## Implementation steps
    #{numbered_section(arguments, "implementation_steps", default_implementation_steps())}

    ## Verification method
    #{bullet_section(arguments, "verification_method", ["Run targeted tests and any configured smoke-safe hook before commit."])}

    ## Open questions or blockers
    #{bullet_section(arguments, "open_questions_or_blockers", ["None recorded by the tool caller."])}

    ## Planning gate status
    This artifact was produced by the `superpowers_writing_plans` dynamic tool and can be recorded in Linear, a PR body, or a workpad before implementation.
    """
    |> String.trim()
  end

  defp issue_heading(arguments) do
    identifier = text_value(arguments, "issue_identifier") || "unknown issue"
    title = text_value(arguments, "title") || "Untitled"
    context = text_value(arguments, "context")

    base = "**Issue:** #{identifier} - #{title}"

    case context do
      nil -> base
      context -> base <> "\n\n**Context:** " <> context
    end
  end

  defp fallback_requirement(arguments) do
    case text_value(arguments, "description") do
      nil -> ["Clarify the issue requirements, constraints, and expected proof of work."]
      description -> [description]
    end
  end

  defp default_implementation_steps do
    [
      "Read the issue, linked repository context, and existing tests.",
      "Confirm the current branch and sync from the expected default branch.",
      "Add or update a focused failing test when the change is behavioral.",
      "Implement the smallest complete change.",
      "Run targeted validation and inspect output for unexpected warnings.",
      "Commit, push, and open or update the PR with the Linear key and validation notes."
    ]
  end

  defp bullet_section(arguments, key, fallback) do
    arguments
    |> list_value(key)
    |> case do
      [] -> fallback
      values -> values
    end
    |> Enum.map_join("\n", &"- #{&1}")
  end

  defp numbered_section(arguments, key, fallback) do
    arguments
    |> list_value(key)
    |> case do
      [] -> fallback
      values -> values
    end
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {value, index} -> "#{index}. #{value}" end)
  end

  defp list_value(arguments, key) when is_map(arguments) do
    case Map.get(arguments, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_binary(value) ->
        value
        |> String.split(["\n", "\r"], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp text_value(arguments, key) when is_map(arguments) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp authorize_linear_graphql_query(query, opts) when is_binary(query) do
    cond do
      not mutation_document?(query) ->
        :ok

      Keyword.get(opts, :allow_mutations, false) ->
        authorize_linear_mutation_fields(query)

      System.get_env("SYMPHONY_ALLOW_LINEAR_GRAPHQL_MUTATIONS") == "true" ->
        authorize_linear_mutation_fields(query)

      true ->
        {:error, :linear_graphql_mutation_not_allowed}
    end
  end

  defp mutation_document?(query) when is_binary(query) do
    Regex.match?(~r/(^|[\s{])mutation\b/i, query)
  end

  defp authorize_linear_mutation_fields(query) do
    field_names = linear_mutation_field_names(query)
    disallowed = Enum.reject(field_names, &MapSet.member?(@allowed_linear_mutation_fields, &1))

    cond do
      field_names == [] ->
        {:error, {:linear_graphql_mutation_fields_not_allowed, []}}

      disallowed == [] ->
        :ok

      true ->
        {:error, {:linear_graphql_mutation_fields_not_allowed, disallowed}}
    end
  end

  defp linear_mutation_field_names(query) do
    query
    |> strip_graphql_comments()
    |> strip_graphql_strings()
    |> mutation_body()
    |> scan_graphql_call_fields()
  end

  defp strip_graphql_comments(query) do
    Regex.replace(~r/#.*$/m, query, "")
  end

  defp strip_graphql_strings(query) do
    query
    |> then(&Regex.replace(~r/"""(?:.|\n)*?"""/, &1, "\"\""))
    |> then(&Regex.replace(~r/"(?:\\.|[^"\\])*"/, &1, "\"\""))
  end

  defp mutation_body(query) do
    case Regex.run(~r/\bmutation\b(?:\s+[A-Za-z_][A-Za-z0-9_]*)?(?:\s*\([^{}]*\))?\s*\{(.*)\}\s*$/is, query) do
      [_, body] -> body
      _ -> query
    end
  end

  defp scan_graphql_call_fields(body) do
    ~r/(?:^|[{\s])([A-Za-z_][A-Za-z0-9_]*)\s*\(/
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(output) when is_binary(output) do
    dynamic_tool_response(true, output)
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:linear_graphql_mutation_not_allowed) do
    %{
      "error" => %{
        "message" => "`linear_graphql` only allows read-only queries by default. Set `SYMPHONY_ALLOW_LINEAR_GRAPHQL_MUTATIONS=true` for trusted comment mutation workflows."
      }
    }
  end

  defp tool_error_payload({:linear_graphql_mutation_fields_not_allowed, fields}) do
    %{
      "error" => %{
        "message" => "`linear_graphql` mutation access is limited to commentCreate/commentUpdate; issue state and other Linear writes remain runtime-owned.",
        "disallowedFields" => fields
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
