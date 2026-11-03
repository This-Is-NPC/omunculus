defmodule Omunculus.Errors do
  @moduledoc """
  The sentence each error term reads as, the same for every adapter
  (the command line, the HTTP server) and for tools that report a core
  error; a term without a sentence of its own reads as itself.
  """

  alias Omunculus.Tools.Out

  @spec format(term) :: String.t()
  def format({:config, :missing, path}), do: "no config at #{path}"

  def format({:config, :stale}),
    do: "omunculus.toml changed since it was read; read it again"

  def format({:config, :invalid_item}),
    do:
      "the item is not agents, models, workflows, workspaces, auth or secrets .<name>, policy or access, " <>
        "with a JSON table or null"

  def format({:tool_failed, output}), do: output

  def format({:model_test, :unknown, name}), do: "no model #{name}"

  def format({:model_test, :command}),
    do: "a command model runs in the sandbox of an agent's ceiling; a run tests it"

  def format({:execution, :missing, keys}) do
    "omunculus.toml is missing [execution]; required keys: #{Enum.join(keys, ", ")}"
  end

  def format({:execution, {:unknown_resource, name}}) do
    "omunculus.toml [execution] resources includes unknown name #{name}"
  end

  def format({:models, :missing}) do
    "omunculus.toml is missing [models]"
  end

  def format({:store, :missing}) do
    "omunculus.toml is missing [store]"
  end

  def format({:policy, {:required, :request_routes}}),
    do: "omunculus.toml [policy] request_routes is required, a nonempty list of routes"

  def format({:policy, {:invalid, :request_routes}}),
    do: "omunculus.toml [policy] request_routes must be a nonempty list of valid routes"

  def format({:policy, {:invalid, :max_retries}}) do
    "omunculus.toml [policy] max_retries is required, a non-negative integer"
  end

  def format({:policy, {:invalid, :max_reopens}}) do
    "omunculus.toml [policy] max_reopens must be a non-negative integer"
  end

  def format({:policy, {:invalid, key}})
      when key in [:last_run_output_bytes, :tool_output_bytes, :conversation_bytes] do
    "omunculus.toml [policy] #{key} must be a positive integer"
  end

  def format({:policy, {:invalid, key}})
      when key in [:session_ttl_ms, :session_max_bytes] do
    "omunculus.toml [policy] #{key} must be a positive integer"
  end

  def format({:policy, {:invalid, :session}}) do
    "omunculus.toml [policy] session_ttl_ms and session_max_bytes go together"
  end

  def format({:policy, {:invalid, :send_catalog}}) do
    "omunculus.toml [policy] send_catalog must be true or false"
  end

  def format({:execution, {:sandbox, :missing}}) do
    "omunculus.toml is missing [execution.sandbox]"
  end

  def format({:agent, name, {:invalid, :model}}) do
    "omunculus.toml agent #{name} is missing model"
  end

  def format({:auth, :not_logged_in, id}), do: "not logged in to #{id}"

  def format({:overrides, tool, {:not_chainable, name}}) do
    "overrides.#{tool}.chains names #{name}, which the #{tool} manifest does not chain"
  end

  def format({:overrides, tool, {:invalid, :then}}) do
    "overrides of #{tool} leave a then outside its chains or with end not last"
  end

  def format({:overrides, tool, {:unknown_schema, variant}}) do
    "overrides.#{tool}.schema names #{variant}, which the #{tool} manifest does not declare"
  end

  def format({:packs, {pack, :requires, lacked}}) when is_map(lacked) do
    tools = Enum.map_join(Enum.sort(lacked), "; ", fn {tool, where} -> "#{tool} (#{where})" end)

    "pack #{pack} requires tools the project lacks: #{tools}; add a [tools] path that holds them or import the pack that brings them"
  end

  def format({:worktree, reason}) when is_binary(reason), do: reason

  def format(:no_runs), do: "no runs"
  def format(:project_in_use), do: "project is in use by another Omunculus process"

  def format(:store_requires_recreation),
    do: "store tables differ from this schema; recreate the store"

  def format(:not_project_owner),
    do: "only the owner of the project config may bootstrap access"

  def format({:unknown_run, id}), do: "unknown run #{id}"
  def format(:no_assembled), do: "no assembled prompt"
  def format({:assemble, :missing}), do: "omunculus.toml is missing assemble"
  def format({:assemble, :empty}), do: "assemble returned an empty prompt"

  def format({:runs, reasons}), do: Enum.map_join(reasons, "\n", &format/1)

  def format({:prompt, {:agent_required, depth, names}}),
    do: "several agents have depth #{depth}: #{Enum.join(names, ", ")}"

  def format({:prompt, {:no_agent_at_depth, depth}}), do: "no agent has depth #{depth}"
  def format({:prompt, {:not_at_depth_0, name}}), do: "#{name} is not an agent of depth 0"
  def format(:access_disabled), do: "omunculus.toml has no [access] table"

  def format({adapter, {:http, status, _body}} = reason)
      when adapter in [:anthropic, :openai] and status in [401, 403],
      do: Out.model_failed(reason) <> "; the key is missing or wrong"

  def format({adapter, {:http, _status, _body}} = reason) when adapter in [:anthropic, :openai],
    do: Out.model_failed(reason)

  def format({:reply, :escalated}), do: "the request was passed up, so it takes no reply here"
  def format({:reply, :closed}), do: "the request is closed"
  def format({:reply, :not_arbiter}), do: "only the request's arbiter may reply to it"

  def format({:reply, {:unknown_option, option, options}}),
    do: "#{option} is not an option of the request; choose one of: #{Enum.join(options, ", ")}"

  def format({:escalate, reason}) when reason in [:invalid_origin, :invalid_origins],
    do: "the requests to pass up must be pending, distinct, and yours to arbitrate"

  def format(reason), do: inspect(reason)
end
