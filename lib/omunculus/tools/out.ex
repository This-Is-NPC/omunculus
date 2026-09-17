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

  @spec user_facing() :: [String.t()]
  def user_facing do
    [
      tools_preamble(),
      more_tools(1),
      requested_by("agent"),
      already_granted("comment"),
      preset_applied("default"),
      no_tools_found(),
      no_comments(),
      empty_inbox(),
      no_text()
    ]
  end
end
