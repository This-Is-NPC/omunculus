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
  def tools_preamble, do: "The tools are in `tools.*`."

  @spec more_tools(non_neg_integer()) :: String.t()
  def more_tools(count), do: "#{count} more tools: search with tool_search."

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
