defmodule Omunculus.Server.OpenAPI do
  @moduledoc "Builds the OpenAPI document from the HTTP router's route declarations."

  @operations %{
    health: %{summary: "Check server health", status: 200, response: :health, public: true},
    openapi: %{
      summary: "Read the OpenAPI document",
      status: 200,
      response: :openapi,
      public: true
    },
    identity: %{summary: "Read the token principal", status: 200, response: "Principal"},
    cli: %{
      summary: "Run a command line on the local socket's project",
      status: 200,
      response: "CliOutput",
      request: "CliCommand"
    },
    create_conversation: %{
      summary: "Create a conversation",
      status: 201,
      response: "CreatedConversation",
      request: "CreateConversation",
      idempotent: true
    },
    list_conversations: %{
      summary: "List visible conversations",
      status: 200,
      response: "Conversations"
    },
    get_conversation: %{summary: "Read a conversation", status: 200, response: "Conversation"},
    snapshot: %{summary: "Read a conversation snapshot", status: 200, response: "Snapshot"},
    list_items: %{summary: "List conversation resources", status: 200, response: "Items"},
    events: %{
      summary: "Read later conversation events",
      status: 200,
      response: "Events",
      cursor: true
    },
    stream: %{
      summary: "Subscribe to later conversation events",
      status: 101,
      response: :stream,
      cursor: true
    },
    send_message: %{
      summary: "Send a message",
      status: 202,
      response: "Accepted",
      request: "SendMessage",
      idempotent: true
    },
    reply_request: %{
      summary: "Reply to a request",
      status: 202,
      response: "Accepted",
      request: "ReplyRequest",
      idempotent: true
    },
    comment: %{
      summary: "Comment on a resource",
      status: 202,
      response: "Accepted",
      request: "Comment",
      idempotent: true
    },
    read_inbox: %{
      summary: "Mark an inbox item read",
      status: 202,
      response: "Accepted",
      idempotent: true
    },
    put_project_member: %{
      summary: "Assign a project member",
      status: 200,
      response: "Updated",
      request: "Membership"
    },
    remove_project_member: %{summary: "Remove a project member", status: 200, response: "Removed"},
    put_conversation_member: %{
      summary: "Assign a conversation member",
      status: 200,
      response: "Updated",
      request: "Membership"
    },
    remove_conversation_member: %{
      summary: "Remove a conversation member",
      status: 200,
      response: "Removed"
    }
  }

  defmacro route(method, path, operation, do: body) do
    unless method in [:get, :post, :delete] and is_binary(path) and
             Map.has_key?(@operations, operation) do
      raise ArgumentError, "invalid OpenAPI route #{inspect({method, path, operation})}"
    end

    quote do
      @openapi_routes {unquote(method), unquote(path), unquote(operation)}

      Plug.Router.match unquote(path), via: unquote(method) do
        unquote(body)
      end
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:openapi_routes) |> Enum.reverse()

    quote do
      def openapi_routes, do: unquote(Macro.escape(routes))
    end
  end

  @spec document([{atom, String.t(), atom}]) :: map
  def document(routes) do
    paths =
      Enum.reduce(routes, %{}, fn {method, path, id}, acc ->
        path = String.replace(path, ~r/:([a-z_]+)/, "{\\1}")

        Map.update(
          acc,
          path,
          %{method => operation(id, path)},
          &Map.put(&1, method, operation(id, path))
        )
      end)

    %{
      openapi: "3.1.0",
      info: %{title: "Omunculus HTTP API", version: "1.0.0"},
      paths: paths,
      security: [%{bearerAuth: []}],
      components: %{
        securitySchemes: %{bearerAuth: %{type: "http", scheme: "bearer", bearerFormat: "JWT"}},
        schemas: schemas()
      }
    }
  end

  defp operation(id, path) do
    spec = Map.fetch!(@operations, id)

    %{
      operationId: Atom.to_string(id),
      summary: spec.summary,
      parameters: parameters(path, spec),
      responses: responses(spec)
    }
    |> maybe_put(:requestBody, spec[:request] && request(spec.request))
    |> maybe_put(:security, if(spec[:public], do: [], else: nil))
  end

  defp parameters(path, spec) do
    path_params =
      Regex.scan(~r/\{([a-z_]+)\}/, path, capture: :all_but_first)
      |> Enum.map(fn [name] ->
        schema =
          if name == "kind",
            do: %{type: "string", enum: ~w(works runs prompts requests inbox)},
            else: %{type: "string"}

        %{name: name, in: "path", required: true, schema: schema}
      end)

    path_params
    |> maybe_append(
      spec[:cursor] &&
        %{
          name: "after",
          in: "query",
          schema: %{type: "string"},
          description: "Opaque event cursor"
        }
    )
    |> maybe_append(
      spec[:idempotent] &&
        %{
          name: "Idempotency-Key",
          in: "header",
          required: true,
          schema: %{type: "string", minLength: 1, maxLength: 128}
        }
    )
  end

  defp responses(spec) do
    success =
      case spec.response do
        :health ->
          %{
            description: "Server is running",
            content: %{"text/plain" => %{schema: %{type: "string"}}}
          }

        :openapi ->
          %{description: "OpenAPI document", content: json(%{type: "object"})}

        :stream ->
          %{
            description:
              "Switches to a WebSocket that sends each later event and partial model reply as a JSON text frame"
          }

        name ->
          %{description: spec.summary, content: json(ref(name))}
      end

    if spec[:public] do
      %{spec.status => success}
    else
      Map.put(common_errors(), spec.status, success)
    end
  end

  defp common_errors do
    for {status, description} <- [
          {400, "Invalid request"},
          {401, "Missing or invalid bearer token"},
          {404, "Resource unavailable"},
          {409, "Command conflict"},
          {422, "Tool refused the command"},
          {500, "Internal server error"}
        ],
        into: %{} do
      {status, %{description: description, content: json(ref("Error"))}}
    end
  end

  defp request(name), do: %{required: true, content: json(ref(name))}
  defp json(schema), do: %{"application/json" => %{schema: schema}}
  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_append(list, nil), do: list
  defp maybe_append(list, value), do: list ++ [value]

  defp object(properties, required \\ []),
    do: %{type: "object", properties: properties, required: required}

  defp string, do: %{type: "string"}
  defp nullable_string, do: %{type: ["string", "null"]}
  defp array(schema), do: %{type: "array", items: schema}

  defp schemas do
    %{
      "Principal" => object(%{issuer: string(), subject: string()}, ~w(issuer subject)),
      "Conversation" =>
        object(
          %{
            id: string(),
            created_at: string(),
            created_issuer: string(),
            created_subject: string()
          },
          ~w(id created_at created_issuer created_subject)
        ),
      "CreatedConversation" => object(%{id: string(), cursor: string()}, ~w(id cursor)),
      "CreateConversation" => object(%{}),
      "Conversations" => object(%{items: array(ref("Conversation"))}, ["items"]),
      "Accepted" =>
        object(
          %{status: %{type: "string", const: "accepted"}, cursor: %{type: ["string", "null"]}},
          ["status", "cursor"]
        ),
      "Error" => object(%{error: string(), message: string()}, ["error"]),
      "CliCommand" => object(%{argv: array(string())}, ["argv"]),
      "CliOutput" => object(%{output: string()}, ["output"]),
      "Updated" => object(%{status: %{type: "string", const: "updated"}}, ["status"]),
      "Removed" => object(%{status: %{type: "string", const: "removed"}}, ["status"]),
      "Membership" =>
        object(%{issuer: string(), subject: string(), role: string()}, ~w(issuer subject role)),
      "SendMessage" => object(%{message: string(), work_id: string()}, ["message"]),
      "ReplyRequest" => object(%{option: string(), body: string()}, ~w(body)),
      "Comment" =>
        object(%{body: string(), work_id: string(), request_id: string(), inbox_id: string()}, [
          "body"
        ]),
      "Work" =>
        object(
          %{
            id: string(),
            parent_id: nullable_string(),
            workspace: nullable_string(),
            assignee: nullable_string(),
            title: string(),
            goal: string(),
            stage: nullable_string(),
            state: string(),
            waiting: nullable_string(),
            created_at: string(),
            updated_at: nullable_string()
          },
          ["id", "title", "goal", "state"]
        ),
      "Run" =>
        object(
          %{
            id: string(),
            work_id: nullable_string(),
            agent: string(),
            depth: string(),
            via: nullable_string(),
            request_id: nullable_string(),
            status: string(),
            started_at: nullable_string(),
            finished_at: nullable_string(),
            origin_issuer: nullable_string(),
            origin_subject: nullable_string()
          },
          ["id", "status"]
        ),
      "Prompt" =>
        object(
          %{
            id: string(),
            kind: string(),
            body: string(),
            run_id: nullable_string(),
            created_at: string(),
            actor_issuer: nullable_string(),
            actor_subject: nullable_string()
          },
          ["id", "kind", "body"]
        ),
      "Request" =>
        object(
          %{
            id: string(),
            run_id: string(),
            agent: string(),
            work_id: nullable_string(),
            options: %{type: "object"},
            arbiter: nullable_string(),
            status: string(),
            created_at: string()
          },
          ["id", "options", "status"]
        ),
      "Inbox" =>
        object(
          %{
            id: string(),
            run_id: string(),
            agent: string(),
            work_id: nullable_string(),
            read_at: nullable_string(),
            created_at: string()
          },
          ["id"]
        ),
      "Items" =>
        object(%{items: array(%{oneOf: Enum.map(~w(Work Run Prompt Request Inbox), &ref/1)})}, [
          "items"
        ]),
      "Snapshot" =>
        object(
          %{
            v: %{type: "integer"},
            conversation: ref("Conversation"),
            cursor: string(),
            works: array(ref("Work")),
            runs: array(ref("Run")),
            prompts: array(ref("Prompt")),
            requests: array(ref("Request")),
            inbox: array(ref("Inbox"))
          },
          ~w(v conversation cursor works runs prompts requests inbox)
        ),
      "Event" =>
        object(
          %{
            v: %{type: "integer"},
            cursor: string(),
            project: string(),
            type: string(),
            at: string(),
            actor: %{
              anyOf: [
                object(
                  %{kind: %{const: "human"}, issuer: string(), subject: string()},
                  ~w(kind issuer subject)
                ),
                object(%{kind: %{const: "agent"}, id: string()}, ~w(kind id)),
                object(%{kind: %{const: "harness"}}, ["kind"]),
                %{type: "null"}
              ]
            },
            origin: %{oneOf: [ref("Principal"), %{type: "null"}]},
            run_id: nullable_string(),
            work_id: nullable_string(),
            request_id: nullable_string(),
            inbox_id: nullable_string(),
            prompt_id: nullable_string(),
            comment_id: nullable_string(),
            body: %{}
          },
          ~w(v cursor project type at)
        ),
      "Events" => object(%{events: array(ref("Event"))}, ["events"])
    }
  end
end
