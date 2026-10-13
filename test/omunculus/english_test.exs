defmodule Omunculus.EnglishTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Out

  @accent ~r/[àáâãéêíóôõúçÀÁÂÃÉÊÍÓÔÕÚÇ]/u

  test "builtin manifest descriptions have no accented characters" do
    Enum.each(manifest_paths(), fn path ->
      {:ok, raw} = Toml.decode_file(path)
      description = Map.get(raw, "description", "")

      refute Regex.match?(@accent, description),
             "#{Path.relative_to(path, Application.app_dir(:omunculus))} has accents"
    end)
  end

  test "builtin tool output strings have no accented characters" do
    Enum.each(user_facing(), fn string ->
      refute Regex.match?(@accent, string), string
    end)
  end

  defp user_facing do
    [
      Out.tools_preamble(),
      Out.skills_preamble(),
      Out.more_tools(1),
      Out.requested_by("agent"),
      Out.refused({:request, {:already_have, "comment"}}),
      Out.refused({:delegate, {:broken_child, "w1"}}),
      Out.refused({:end, :work_open}),
      Out.refused({:end, :root_open}),
      Out.refused({:wait, :not_root}),
      Out.refused({:work, {:agent_not_allowed, "transmute"}}),
      Out.refused({:delegate, :agent_with_workflow}),
      Out.refused({:reopen, {:only_person, "write"}}),
      Out.refused({:reopen, {:cannot_grant, "write"}}),
      Out.refused({:reopen, {:blocked, "write"}}),
      Out.refused({:reply, {:unknown_option, "grant: grant", ["deny", "grant"]}}),
      Out.read_only_workspace(),
      Out.closed_network(),
      Out.invalid_arguments(),
      Out.no_work(),
      Out.preset_applied("default"),
      Out.no_tools_found(),
      Out.no_comments(),
      Out.empty_inbox(),
      Out.no_text(),
      Out.api_key_prompt(),
      Out.logged_in("openai"),
      Out.logged_out("openai"),
      Out.unknown_auth_provider("openai"),
      Out.unknown_auth_kind("oauth"),
      Out.login_tool_failed(),
      Out.chain_failed("end", :after_end),
      Out.unreported(2, "worker", "a work"),
      Out.request_inbox(Out.unreported(1, "worker", "a work"), ["cancel", "retry"]),
      Out.unanswered(
        "lead",
        [%{requester: ~s({"kind":"agent","agent":"worker"}), reason: "Logo?", title: nil}],
        true
      )
    ]
  end

  defp manifest_paths do
    for root <- ["priv/tools", "priv/presets"],
        path <- Path.wildcard(Path.join([Application.app_dir(:omunculus), root, "**", "*.toml"])),
        Path.basename(path) in ["tool.toml", "hook.toml"] do
      path
    end
  end
end
