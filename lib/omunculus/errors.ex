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

  def format({:accounts, :invalid}),
    do:
      "omunculus.toml [accounts] must map names to {kind = \"agent\", agent = ...} or {kind = \"human\", issuer = ..., subject = ...}"

  def format({:accounts, {:invalid, name}}),
    do:
      "omunculus.toml [accounts.#{name}] must be {kind = \"agent\", agent = <an agent>} or {kind = \"human\", issuer = ..., subject = ...}"

  def format({:accounts, {:agent_name, name}}),
    do: "omunculus.toml [accounts.#{name}] is also the name of an agent: pick another name"

  def format({:interceptors, :invalid}),
    do: "omunculus.toml [[interceptors]] must be a list of tables"

  def format({:interceptors, {position, reason}}),
    do: "omunculus.toml [[interceptors]] number #{position}: " <> interceptor_reason(reason)

  def format({:jobs, :invalid}),
    do: "omunculus.toml [jobs] must be a table"

  def format({:jobs, {:unknown_key, key}}),
    do: "omunculus.toml [jobs] has an unknown key #{key}"

  def format({:jobs, {:missing, key}}),
    do: "omunculus.toml [jobs] must give #{key}: it has no default"

  def format({:jobs, {:invalid, key}}) when key in ~w(missed agent_may_create),
    do:
      "omunculus.toml [jobs] #{key} must be " <>
        if(key == "missed", do: "skip or run_once", else: "true or false")

  def format({:jobs, {:invalid, key}})
      when key in ~w(max_parallel min_interval_minutes max_jobs lateness_seconds failures_before_pause),
      do: "omunculus.toml [jobs] #{key} must be a positive integer"

  def format({:jobs, reason}), do: jobs_reason(reason)

  def format({:policy, {:invalid, :default_agent}}) do
    "omunculus.toml [policy] default_agent must name an agent of depth 0 that is not workflow_only"
  end

  def format({:policy, {:invalid, :max_retries}}) do
    "omunculus.toml [policy] max_retries is required, a non-negative integer"
  end

  def format({:policy, {:invalid, :max_reopens}}) do
    "omunculus.toml [policy] max_reopens must be a non-negative integer"
  end

  def format({:policy, {:invalid, :report_required}}) do
    "omunculus.toml [policy] report_required must list report fields: #{Enum.join(Omunculus.Config.report_fields(), ", ")}"
  end

  def format({:policy, {:invalid, key}})
      when key in [
             :last_run_output_bytes,
             :tool_output_bytes,
             :conversation_bytes,
             :memory_bytes,
             :media_bytes
           ] do
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

  def format({:packs, {pack, :omunculus, {requirement, running}}}),
    do:
      "pack #{pack} needs omunculus #{requirement} and this is #{running}: " <>
        "install a newer omunculus, or an older version of the pack"

  def format({:packs, {pack, :header, key}}),
    do:
      "pack #{pack}: [pack] #{key} is missing or not valid; " <>
        "a shareable pack gives a name, a semver version, a one-line description and the omunculus it needs"

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
  def format({:prompt, :subject_line}), do: "a subject is one line of text"

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

  defp jobs_reason(:disabled),
    do: "omunculus.toml has no [jobs] table, so the project has no jobs"

  defp jobs_reason(:one_target), do: "a job aims at one of agent, workflow or tool"
  defp jobs_reason(:in_fire), do: "a run that a job's fire opened may not create or change jobs"
  defp jobs_reason(:unchanged), do: "the job already holds that"
  defp jobs_reason(:no_author), do: "a job is written by a person or an agent"
  defp jobs_reason(:no_owner), do: "a job needs an owner: name one"

  defp jobs_reason(:approval_required),
    do: "an agent may not create a job without a request the person approved: use propose_job"

  defp jobs_reason(:agent_creates_only), do: "an agent may only create jobs"
  defp jobs_reason(:owner_not_self), do: "an agent's job without approval is owned by that agent"
  defp jobs_reason({:unknown, ref}), do: "no job #{ref}"
  defp jobs_reason({:name_taken, name}), do: "a job named #{name} exists"

  defp jobs_reason({:too_many, max}),
    do: "the project holds #{max} jobs, the most [jobs] max_jobs allows"

  defp jobs_reason({:unknown_agent, name}),
    do: "#{name} is not an agent of depth 0 that can run without a work"

  defp jobs_reason({:unknown_workflow, name}), do: "no workflow #{name}"
  defp jobs_reason({:unknown_workspace, name}), do: "no workspace #{name}"
  defp jobs_reason({:unknown_account, name}), do: "#{name} is neither an account nor an agent"
  defp jobs_reason({:unknown_conversation, id}), do: "no conversation #{id}"

  defp jobs_reason({:unknown_timezone, name}),
    do: "#{name} is not a time zone of the host's database"

  defp jobs_reason({:unknown_fire, id}), do: "no fire #{id} of that job"
  defp jobs_reason({:slot_taken, slot}), do: "a fire of that job holds #{slot} already"
  defp jobs_reason({:not_approved, id}), do: "request #{id} is not an approved proposal of a job"

  defp jobs_reason({:fire_state, from, to}), do: "a fire #{from} does not go to #{to}"
  defp jobs_reason({:state, from, to}), do: "a #{from} job cannot #{to}"

  defp jobs_reason({:too_frequent, gap, limit}),
    do:
      "the schedule fires every #{gap} seconds; [jobs] min_interval_minutes allows no less than #{limit}"

  defp jobs_reason({:invalid, "schedule"}),
    do:
      "schedule is a 5-field cron expression, every Nm or Nh, or daily at HH:MM, and fires at least once"

  defp jobs_reason({:invalid, field}), do: "the job's #{field} is missing or not valid"

  defp interceptor_reason(:not_a_table), do: "it must be a table"
  defp interceptor_reason({:unknown_key, key}), do: "#{key} is not a key of an interceptor"

  defp interceptor_reason(:action),
    do: "action is required, one of ask, comment, attach, grant or tool"

  defp interceptor_reason(:tool_required), do: "action = \"tool\" requires tool, the tool's name"
  defp interceptor_reason(:tool_only), do: "tool goes only with action = \"tool\""
  defp interceptor_reason(:tool_has_no_target), do: "action = \"tool\" takes no to"

  defp interceptor_reason({:unknown_name, key, name, names}),
    do:
      "#{key} names #{inspect(name)}, which is neither an account nor an agent; one of: #{Enum.join(names, ", ")}" <>
        if(key == "to", do: ", or requester", else: "")

  defp interceptor_reason({:unknown, key, name}), do: "#{key} #{inspect(name)} is not configured"
  defp interceptor_reason({:invalid, key}), do: "#{key} must be a string"
  defp interceptor_reason(:stage_needs_workflow), do: "stage goes with a workflow"

  defp interceptor_reason({:unknown_stage, workflow, stage}),
    do: "#{inspect(stage)} is not a stage of the workflow #{workflow}"

  defp interceptor_reason(:accounts),
    do: "accounts is required: a non-empty list of account or agent names, in review order"
end
