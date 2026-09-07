defmodule Omunculus.CLI.Help do
  @moduledoc false

  alias Omunculus.CLI.Spec

  def render("root", style), do: render_root(style)
  def render(nil, style), do: render_root(style)

  def render(name, style) do
    case Spec.command(name) do
      nil -> {:error, {:unknown_command, name}}
      cmd -> {:ok, render_command(cmd, style)}
    end
  end

  def usage_error(reason) do
    {message, hint} = describe(reason)

    """
    #{message}

    #{hint}
    """
    |> String.trim_trailing()
  end

  defp render_root(style) do
    {:ok,
     sections([
       about(style, Spec.about(), Spec.long_about()),
       usage_line("#{Spec.bin()} [OPTIONS] [COMMAND]"),
       commands_block(),
       flags_block(visible_root_flags(), style),
       examples_block(style, Spec.examples()),
       exit_block(style)
     ])}
  end

  defp render_command(cmd, style) do
    synopsis = command_synopsis(cmd)

    sections([
      about(style, cmd.about, cmd.long_about),
      usage_line(synopsis),
      args_block(cmd.args),
      flags_block(cmd.flags ++ global_visible(), style),
      examples_block(style, cmd.examples),
      exit_block(style)
    ])
  end

  defp command_synopsis(cmd) do
    flags = if cmd.flags == [], do: "", else: " [OPTIONS]"

    args =
      Enum.map_join(cmd.args, " ", fn
        %{required: true, variadic: true, metavar: m} -> "<#{m}>..."
        %{required: true, metavar: m} -> "<#{m}>"
        %{metavar: m} -> "[#{m}]"
      end)

    args = if args == "", do: "", else: " " <> args
    "#{Spec.bin()} #{cmd.name}#{flags}#{args}"
  end

  defp about(:long, _short, long) when is_binary(long), do: long
  defp about(_, short, _), do: short

  defp usage_line(synopsis), do: "Usage: #{synopsis}"

  defp commands_block do
    rows =
      Spec.commands()
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, cmd} -> {name, cmd.about} end)

    "Commands:\n" <> format_rows(rows)
  end

  defp args_block([]), do: nil

  defp args_block(args) do
    rows =
      Enum.map(args, fn arg ->
        label = if arg.required, do: "<#{arg.metavar}>", else: "[#{arg.metavar}]"
        label = if arg[:variadic], do: label <> "...", else: label
        {label, arg.help}
      end)

    "Arguments:\n" <> format_rows(rows)
  end

  defp flags_block(flags, style) do
    rows =
      flags
      |> Enum.reject(& &1.builtin)
      |> Kernel.++(Enum.filter(flags, & &1.builtin))
      |> Enum.map(&flag_row(&1, style))

    "Options:\n" <> format_rows(rows)
  end

  defp flag_row(flag, style) do
    {left(flag), right(flag, style)}
  end

  defp left(flag) do
    short = if flag.short, do: "-#{flag.short}, ", else: "    "
    long = if flag.long, do: "--#{flag.long}", else: ""
    value = if flag.value, do: " <#{flag.value}>", else: ""
    short <> long <> value
  end

  defp right(flag, style) do
    parts = [flag.help, env_note(flag), default_note(flag)]

    Enum.join(Enum.reject(parts, &is_nil/1), " ")
    |> then(fn text ->
      if style == :long and flag.hide_env_values, do: text, else: text
    end)
  end

  defp env_note(%{env: nil}), do: nil
  defp env_note(%{env: env}), do: "[env: #{env}]"
  defp default_note(%{default: nil}), do: nil
  defp default_note(%{default: default}), do: "[default: #{default}]"

  defp examples_block(:short, _), do: nil
  defp examples_block(_, []), do: nil

  defp examples_block(:long, examples) do
    body =
      Enum.map_join(examples, "\n", fn
        {code, nil, nil} -> "  #{code}"
        {code, header, nil} -> "  #{header}:\n    #{code}"
        {code, header, help} -> "  #{header}:\n    #{code}\n    #{help}"
      end)

    "Examples:\n" <> body
  end

  defp exit_block(:short), do: nil

  defp exit_block(:long) do
    rows = Enum.map(Spec.exit_codes(), fn {n, help} -> {Integer.to_string(n), help} end)
    "Exit codes:\n" <> format_rows(rows)
  end

  defp visible_root_flags do
    Spec.root_flags()
  end

  defp global_visible do
    Enum.filter(Spec.root_flags(), & &1.global)
  end

  defp format_rows(rows) do
    width =
      rows
      |> Enum.map(fn {left, _} -> String.length(left) end)
      |> Enum.max(fn -> 0 end)
      |> then(&max(&1, 8))

    Enum.map_join(rows, "\n", fn {left, right} ->
      "  " <> String.pad_trailing(left, width) <> "  " <> to_string(right || "")
    end)
  end

  defp sections(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp describe({:unknown_flag, token}),
    do:
      {"error: unexpected argument '" <> token <> "' found",
       "Run '" <> Spec.bin() <> " --help' for usage."}

  defp describe({:missing_flag_value, token}),
    do:
      {"error: a value is required for '" <> token <> "' but none was supplied",
       "Run '" <> Spec.bin() <> " --help' for usage."}

  defp describe({:missing_required_arg, name}),
    do:
      {"error: the following required argument was not provided: <#{name}>",
       "Run '" <> Spec.bin() <> " --help' for usage."}

  defp describe({:unexpected_arg, token}),
    do:
      {"error: unexpected argument '" <> token <> "' found",
       "Run '" <> Spec.bin() <> " --help' for usage."}

  defp describe({:unknown_command, name}),
    do:
      {"error: unrecognized subcommand '" <> name <> "'",
       "Run '" <> Spec.bin() <> " --help' for usage."}

  defp describe({:invalid_delay, raw}),
    do: {"error: invalid delay #{inspect(raw)}", "Use a duration such as 500ms, 2s, or 10."}

  defp describe({:unknown_event_type, type}),
    do:
      {"error: unknown event type #{inspect(type)}",
       "Run 'omunculus events catalog' to list the types."}

  defp describe({:not_injectable, type}),
    do:
      {"error: #{type} cannot be emitted from outside",
       "Only commands marked injectable in the catalog are accepted."}

  defp describe({:invalid_flag_value, flag, raw}),
    do: {"error: invalid value #{inspect(raw)} for #{flag}", "Use a non-negative integer."}

  defp describe({:invalid_increment, raw}),
    do: {"error: invalid increment #{inspect(raw)}", "Use a non-zero integer."}

  defp describe({:option_requires_tool, option, tool}),
    do:
      {"error: option #{option} requires tool #{inspect(tool)}",
       "Add '--tools #{tool}' or remove #{option}."}

  defp describe(:benchmark_limit_required),
    do:
      {"error: benchmark requires --max-agents or --memory-limit",
       "Choose a maximum agent count, a soft RSS limit (for example 512M), or both."}

  defp describe({:benchmark_limit_required, _}),
    do:
      {"error: benchmark requires --max-agents or --memory-limit",
       "Choose a maximum agent count, a soft RSS limit (for example 512M), or both."}

  defp describe({:benchmark_tree_limit_required, _}),
    do:
      {"error: agent-tree requires --max-trees or --memory-limit",
       "Choose a tree count, a soft RSS limit (for example 512M), or both."}

  defp describe({:invalid_memory_limit, raw}),
    do:
      {"error: invalid --memory-limit #{inspect(raw)}",
       "Use bytes or a K/M/G value such as 512M."}

  defp describe({:invalid_max_agents, raw}),
    do: {"error: invalid --max-agents #{inspect(raw)}", "Use a positive integer."}

  defp describe({:invalid_max_trees, raw}),
    do: {"error: invalid --max-trees #{inspect(raw)}", "Use a positive integer."}

  defp describe({:invalid_tree_shape, raw}),
    do:
      {"error: invalid --tree-shape #{inspect(raw)}",
       "Use comma-separated positive widths such as 1,1,2,4; each width must be a multiple of its parent width."}

  defp describe({:invalid_tree_mode, mode}),
    do:
      {"error: invalid --tree-mode #{inspect(mode)}",
       "Only resident is supported; durable mode is documented in docs/to-be/execution-model.md."}

  defp describe({:invalid_scenario, raw}),
    do:
      {"error: invalid --scenario #{inspect(raw)}",
       "Use actor-density, agent-tree, or http-load."}

  defp describe({:invalid_http_concurrency, raw}),
    do: {"error: invalid --http-concurrency #{inspect(raw)}", "Use a positive integer."}

  defp describe({:invalid_cpu_limit, raw, available}),
    do:
      {"error: invalid --cpu-limit #{inspect(raw)}",
       "Use a positive integer no greater than #{available} schedulers."}

  defp describe({:provider_not_supported, provider, scenario}),
    do:
      {"error: provider #{inspect(provider)} is not supported for #{inspect(scenario)}",
       "Use --provider stub for http-load; actor-density never sends requests."}

  defp describe({:unknown_workspace, name}),
    do:
      {"error: unknown workspace #{inspect(name)}",
       "Use a [workspaces.*] id from the config file."}

  defp describe({:unknown_session_action, action}),
    do:
      {"error: unknown session action #{inspect(action)}",
       "Use 'omunculus session create' or 'omunculus session list'."}

  defp describe({:unknown_workspace_action, action}),
    do:
      {"error: unknown workspace action #{inspect(action)}",
       "Use 'omunculus workspace attach' or 'omunculus workspace detach'."}

  defp describe(other),
    do: {"error: #{inspect(other)}", "Run '" <> Spec.bin() <> " --help' for usage."}
end
