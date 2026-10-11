defmodule Omunculus.Tools.Out do
  @moduledoc """
  Builds the `out` map every builtin tool and hook returns, and holds the
  user-visible strings those tools and the harness emit.
  """

  @spec ok(String.t(), [map]) :: map
  def ok(output \\ "", emit \\ []) do
    %{"ok" => true, "output" => output, "emit" => emit}
  end

  @spec fail(String.t()) :: map
  def fail(message) do
    %{"ok" => false, "output" => message, "emit" => []}
  end

  @spec tools_preamble() :: String.t()
  def tools_preamble,
    do:
      "The tools are in `tools.*`. Only those listed here are yours; ask for another with request_access."

  @spec skills_preamble() :: String.t()
  def skills_preamble, do: "Read a skill with the skill tool before you follow it."

  @spec more_tools(non_neg_integer()) :: String.t()
  def more_tools(count), do: "#{count} more tools: search with tool_search."

  @doc """
  Keeps at most `limit` bytes of `text`, cut on a character boundary,
  and a line saying how many bytes were cut. A nil `limit` keeps it all.
  """
  @spec cut(String.t(), pos_integer | nil) :: String.t()
  def cut(text, limit) when is_nil(limit) or byte_size(text) <= limit, do: text

  def cut(text, limit) do
    kept =
      case :unicode.characters_to_binary(binary_part(text, 0, limit)) do
        {_incomplete_or_error, valid, _rest} -> valid
        valid -> valid
      end

    kept <> "\n" <> bytes_cut(byte_size(text) - byte_size(kept))
  end

  @spec bytes_cut(pos_integer) :: String.t()
  def bytes_cut(count), do: "(#{count} bytes cut)"

  @spec lines_shown(pos_integer, non_neg_integer, non_neg_integer) :: String.t()
  def lines_shown(first, last, total), do: "(lines #{first}-#{last} of #{total})"

  @doc """
  Joins at most `limit` of `matches`, one per line, and a last line
  saying how many more there are. A nil `limit` keeps them all.
  """
  @spec listed([String.t()], pos_integer | nil) :: String.t()
  def listed(matches, limit) when is_nil(limit) or length(matches) <= limit,
    do: Enum.join(matches, "\n")

  def listed(matches, limit) do
    {shown, rest} = Enum.split(matches, limit)
    Enum.join(shown ++ [more_matches(length(rest))], "\n")
  end

  defp more_matches(count),
    do:
      "(#{count} more #{if count == 1, do: "match", else: "matches"}: narrow the path or pattern)"

  @spec requested_by(String.t()) :: String.t()
  def requested_by(agent), do: "requested by #{agent}"

  @spec preset_applied(String.t()) :: String.t()
  def preset_applied(name), do: "preset #{name} applied"

  @spec no_tools_found() :: String.t()
  def no_tools_found, do: "no tools found"

  @spec no_comments() :: String.t()
  def no_comments, do: "no comments"

  @spec empty_inbox() :: String.t()
  def empty_inbox, do: "empty inbox"

  @spec no_text() :: String.t()
  def no_text, do: "(no text)"

  @spec api_key_prompt() :: String.t()
  def api_key_prompt, do: "api key: "

  @spec logged_in(String.t()) :: String.t()
  def logged_in(provider), do: "logged in to #{provider}"

  @spec logged_out(String.t()) :: String.t()
  def logged_out(provider), do: "logged out of #{provider}"

  @spec unknown_auth_provider(String.t()) :: String.t()
  def unknown_auth_provider(provider), do: "unknown auth provider: #{provider}"

  @spec unknown_auth_kind(String.t()) :: String.t()
  def unknown_auth_kind(kind), do: "unknown auth kind: #{kind}"

  @spec login_tool_failed() :: String.t()
  def login_tool_failed, do: "login tool failed"

  @spec unreported(pos_integer) :: String.t()
  def unreported(runs),
    do:
      "The work stopped without a report after #{runs} #{if runs == 1, do: "run", else: "runs"}."

  @spec request_inbox(String.t(), String.t(), [String.t()]) :: String.t()
  def request_inbox(request_id, reason, options),
    do: "#{reason} Reply to request #{request_id} with #{Enum.join(options, " or ")}."

  @spec unanswered(String.t(), String.t()) :: String.t()
  def unanswered(request_id, agent),
    do:
      "#{agent} ended its run without answering request #{request_id}; it is yours to answer with"

  @spec answer_request() :: String.t()
  def answer_request,
    do:
      "This run is for answering it: call reply with your answer in body, optionally choosing one of these options, before anything else."

  @spec read_only_workspace() :: String.t()
  def read_only_workspace,
    do: "The workspace is read-only in this run: writing, moving or deleting needs sandbox.write."

  @spec closed_network() :: String.t()
  def closed_network,
    do:
      "The network is closed in this run, also to this machine: localhost and 127.0.0.1 are the sandbox's own, so nothing listening outside it answers there. Downloading or reaching any host, local or not, needs sandbox.network, which request_access can ask for."

  @spec not_text(String.t(), non_neg_integer) :: String.t()
  def not_text(path, bytes), do: "#{path} is not a text file (#{bytes} bytes)"

  @spec resume() :: String.t()
  def resume,
    do:
      "Your last run ended without done, work or break: go on with the work and end it with one of them."

  @spec answered(String.t() | nil) :: String.t()
  def answered(nil), do: "answered: the reply is below"
  def answered(option), do: "answered #{option}: the reply is below"

  @spec not_yours(String.t()) :: String.t()
  def not_yours(name),
    do:
      "refused: #{name} is not one of your tools; if the work needs it, ask with one request_access for it and everything else the work lacks"

  @doc "What a model reads of done or break in a run without a work."
  @spec no_work() :: String.t()
  def no_work,
    do:
      "refused: this run has no work to close: answer the person in plain text, or hand the work down with work"

  @doc "What a model reads of a call whose arguments were not a JSON object."
  @spec invalid_arguments() :: String.t()
  def invalid_arguments,
    do: "refused: the arguments are not a JSON object; call the tool again with them as one"

  @doc "What a model reads of a call that failed: a text as it is, anything else inspected."
  @spec failure(term) :: String.t()
  def failure(reason) when is_binary(reason), do: reason
  def failure(reason), do: inspect(reason)

  @spec refused(term) :: String.t()
  def refused({:request, {:blocked, name}}),
    do:
      "refused: no one can grant #{name} to this run: it is not in the catalog, or the configuration denies it; name a tool as your tool list writes it, with no prefix (bash, not functions.bash)"

  def refused({:request, {:already_have, names}}),
    do: "refused: you already have #{names}; use it rather than asking"

  def refused({:delegate, {:broken_child, work_id}}),
    do:
      "refused: work #{work_id} below yours broke and waits on you: reopen it with instructions, or break to pass it up"

  def refused({:work, :no_delegate}),
    do:
      "refused: this run cannot delegate, so it cannot hand a work to an agent below; a work naming no agent stays yours"

  def refused({tag, {:agent_not_allowed, agent}}) when tag in [:work, :delegate],
    do:
      "refused: #{agent} is not an agent a work can go to: name one under ## Agents as it is written there, or a workflow it shows"

  def refused({tag, :agent_with_workflow}) when tag in [:work, :delegate],
    do: "refused: a work names an agent or a workflow, not both"

  def refused({tag, {:workflow_required, [only]}}) when tag in [:work, :delegate],
    do: "refused: works at that depth go through the workflow #{only}: leave agent out"

  def refused({tag, {:workflow_required, names}}) when tag in [:work, :delegate],
    do:
      "refused: works at that depth go through one of the workflows #{Enum.join(names, ", ")}: name one as workflow"

  def refused({tag, {:workflow_not_allowed, name, names}}) when tag in [:work, :delegate],
    do:
      "refused: #{name} is not a workflow a work can go through there; name one of: #{Enum.join(names, ", ")}"

  def refused({:reply, {:unknown_option, option, options}}),
    do:
      "refused: #{inspect(option)} is not an option of this request; give option as one of: #{Enum.join(options, ", ")}"

  def refused({:reopen, {:only_person, name}}),
    do:
      "refused: only the person may grant #{name}: reopen without granting it and have the agent ask for it with request_access"

  def refused({:reopen, {:cannot_grant, name}}),
    do:
      "refused: you cannot grant #{name}: reopen without granting it and have the agent ask for it with request_access"

  def refused({:reopen, {:blocked, name}}),
    do:
      "refused: no one can grant #{name} to that agent: it is not in the catalog, or the configuration denies it"

  def refused(reason), do: "refused: #{inspect(reason)}"

  @spec chain_failed(String.t(), term) :: String.t()
  def chain_failed(name, reason), do: "chain failed at #{name}: #{chain_reason(reason)}"

  defp chain_reason(:not_chainable), do: "not in the chains of the tool that chained it"
  defp chain_reason(:loop), do: "already in the chain"
  defp chain_reason(:after_end), do: "after end"
  defp chain_reason(:unknown_tool), do: "unknown tool"
  defp chain_reason(:not_triggered), do: "not triggered by chain"
  defp chain_reason(:not_have), do: "not have in this run"
  defp chain_reason({:failed, output}), do: output
  defp chain_reason(reason), do: inspect(reason)
end
