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

  @spec more_matches(pos_integer) :: String.t()
  def more_matches(count), do: "(#{count} more #{if count == 1, do: "match", else: "matches"})"

  @spec requested_by(String.t()) :: String.t()
  def requested_by(agent), do: "requested by #{agent}"

  @spec already_granted(String.t()) :: String.t()
  def already_granted(name), do: "already granted: #{name}"

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
    do: "This run is for answering it: call reply with one of these options before anything else."

  @spec not_text(String.t(), non_neg_integer) :: String.t()
  def not_text(path, bytes), do: "#{path} is not a text file (#{bytes} bytes)"

  @spec resume() :: String.t()
  def resume, do: "Go on with the work."

  @spec answered() :: String.t()
  def answered, do: "answered: the reply is below"

  @spec not_yours(String.t()) :: String.t()
  def not_yours(name),
    do:
      "refused: #{name} is not one of your tools; ask for it with request_access if the work needs it"

  @doc "What a model reads of a call that failed: a text as it is, anything else inspected."
  @spec failure(term) :: String.t()
  def failure(reason) when is_binary(reason), do: reason
  def failure(reason), do: inspect(reason)

  @spec refused(term) :: String.t()
  def refused({:request, {:blocked, name}}),
    do:
      "refused: no one can grant #{name} to this run: it is not in the catalog, or the configuration denies it"

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
