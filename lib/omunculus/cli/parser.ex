defmodule Omunculus.CLI.Parser do
  @moduledoc false

  # Argv grammar follows https://usage.jdx.dev/spec/argv for the subset this
  # CLI declares: exact long names, attached/detached values, short bundles,
  # `--` separator, command-line then env then default, unknown flags error.
  # `default_subcommand` only catches unmatched *words*, never flags. Run
  # flags are in scope at the root so `omunculus --preset plan DIR INSTR`
  # works the same as `omunculus run --preset plan DIR INSTR`.

  alias Omunculus.CLI.Spec

  def parse(argv, env \\ System.get_env()) when is_list(argv) and is_map(env) do
    state = %{
      command: nil,
      spec: root_spec(),
      flags: %{},
      action: nil,
      stop: false,
      positionals: []
    }

    case walk(argv, state) do
      {:ok, state} ->
        flags_spec = if state.command, do: command_spec(state.command), else: state.spec
        flags = fill_non_argv(state.flags, flags_spec, env)
        finish(state.command, flags_spec, flags, state.positionals, state.action)

      {:error, _} = err ->
        err
    end
  end

  defp root_spec do
    run = Spec.command(Spec.default_subcommand())

    %{
      name: "root",
      about: Spec.about(),
      long_about: Spec.long_about(),
      arg_required_else_help: Spec.arg_required_else_help(),
      args: [],
      flags: Spec.root_flags(),
      effective_flags: Spec.root_flags() ++ run.flags,
      examples: Spec.examples()
    }
  end

  defp command_spec(name) do
    cmd = Spec.command(name) || %{flags: [], args: [], arg_required_else_help: false}

    inherited =
      Enum.filter(Spec.root_flags(), fn flag ->
        flag.global or flag.action != nil
      end)

    Map.put(cmd, :effective_flags, inherited ++ cmd.flags)
  end

  defp walk([], state), do: {:ok, %{state | positionals: Enum.reverse(state.positionals)}}

  defp walk(["--" | rest], state), do: walk(rest, %{state | stop: true})

  defp walk([token | rest], %{stop: true} = state) do
    walk(rest, %{state | positionals: [token | state.positionals]})
  end

  defp walk([token | rest], state) do
    cond do
      long?(token) ->
        consume_long(token, rest, state)

      short_bundle?(token) ->
        consume_shorts(token, rest, state)

      true ->
        consume_word(token, rest, state)
    end
  end

  defp consume_word(token, rest, %{command: nil} = state) do
    if Map.has_key?(Spec.commands(), token) do
      walk(rest, %{state | command: token, spec: command_spec(token)})
    else
      walk([token | rest], %{
        state
        | command: Spec.default_subcommand(),
          spec: command_spec(Spec.default_subcommand())
      })
    end
  end

  defp consume_word(token, rest, state) do
    walk(rest, %{state | positionals: [token | state.positionals]})
  end

  defp consume_long(token, rest, state) do
    {name, attached} = split_long(token)

    case find_flag(state.spec.effective_flags, long: name) do
      nil ->
        {:error, {:unknown_flag, token}}

      flag ->
        with {:ok, state, rest} <- apply_flag(flag, attached, rest, state, token) do
          walk(rest, state)
        end
    end
  end

  defp consume_shorts(token, rest, state) do
    letters = token |> String.trim_leading("-") |> String.graphemes()
    consume_short_letters(letters, rest, state, token)
  end

  defp consume_short_letters([], rest, state, _token), do: walk(rest, state)

  defp consume_short_letters([letter | more], rest, state, token) do
    case find_flag(state.spec.effective_flags, short: letter) do
      nil ->
        {:error, {:unknown_flag, token}}

      flag ->
        cond do
          flag.action != nil ->
            consume_short_letters(more, rest, %{state | action: flag.action}, token)

          flag.value == nil ->
            consume_short_letters(more, rest, put_switch(state, flag), token)

          more == [] ->
            with {:ok, state, rest} <- apply_flag(flag, nil, rest, state, "-" <> letter) do
              walk(rest, state)
            end

          hd(more) == "=" ->
            attached = Enum.join(tl(more))

            with {:ok, state, rest} <- apply_flag(flag, attached, rest, state, "-" <> letter) do
              walk(rest, state)
            end

          true ->
            attached = Enum.join(more)

            with {:ok, state, rest} <- apply_flag(flag, attached, rest, state, "-" <> letter) do
              walk(rest, state)
            end
        end
    end
  end

  defp apply_flag(flag, attached, rest, state, token) do
    cond do
      flag.action != nil ->
        {:ok, %{state | action: flag.action}, rest}

      flag.value == nil ->
        {:ok, put_switch(state, flag), rest}

      attached != nil ->
        {:ok, put_value(state, flag, attached), rest}

      rest == [] ->
        {:error, {:missing_flag_value, token}}

      flag_like?(hd(rest)) and not number_value?(hd(rest)) ->
        {:error, {:missing_flag_value, token}}

      true ->
        [value | rest] = rest
        {:ok, put_value(state, flag, value), rest}
    end
  end

  defp put_switch(state, flag), do: %{state | flags: Map.put(state.flags, flag.name, true)}

  defp put_value(state, flag, raw) do
    value =
      case flag.delimiter do
        nil -> raw
        delim -> String.split(raw, delim, trim: true)
      end

    %{state | flags: Map.put(state.flags, flag.name, value)}
  end

  defp fill_non_argv(flags, spec, env) do
    Enum.reduce(spec.effective_flags, flags, fn flag, acc ->
      cond do
        Map.has_key?(acc, flag.name) ->
          acc

        flag.action != nil ->
          acc

        is_binary(flag.env) and Map.has_key?(env, flag.env) ->
          raw = Map.fetch!(env, flag.env)

          value =
            cond do
              flag.value == nil -> truthy_env?(raw)
              flag.delimiter -> String.split(raw, flag.delimiter, trim: true)
              true -> raw
            end

          Map.put(acc, flag.name, value)

        flag.default != nil ->
          Map.put(acc, flag.name, flag.default)

        true ->
          acc
      end
    end)
  end

  defp finish(command, spec, flags, positionals, action) do
    cond do
      action == :version ->
        {:ok, %{command: :version, flags: flags}}

      action in [:help_short, :help_long] ->
        target = if command in [nil, "root"], do: "root", else: command
        {:ok, %{command: :help, target: target, style: help_style(action), flags: flags}}

      command == "help" ->
        target =
          case positionals do
            [name | _] -> name
            _ -> "root"
          end

        {:ok, %{command: :help, target: target, style: :long, flags: flags}}

      spec.arg_required_else_help and positionals == [] ->
        {:ok,
         %{
           command: :help,
           target: command || "root",
           style: :short,
           flags: flags,
           else_help: true
         }}

      true ->
        command = command || Spec.default_subcommand()
        spec = if spec.name == "root", do: command_spec(command), else: spec

        case bind_args(spec.args, positionals) do
          {:ok, args} ->
            {:ok, %{command: String.to_atom(command), args: args, flags: flags}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp bind_args(defs, positionals), do: bind_args(defs, positionals, %{})

  defp bind_args([], [], acc), do: {:ok, acc}
  defp bind_args([], extras, _acc), do: {:error, {:unexpected_arg, hd(extras)}}

  defp bind_args([%{variadic: true} = arg | _], values, acc) do
    needed = Map.get(arg, :var_min, 0)

    cond do
      arg.required and values == [] -> {:error, {:missing_required_arg, arg.metavar}}
      length(values) < needed -> {:error, {:missing_required_arg, arg.metavar}}
      true -> {:ok, Map.put(acc, arg.name, Enum.join(values, " "))}
    end
  end

  defp bind_args([arg | rest], [], acc) do
    if arg.required,
      do: {:error, {:missing_required_arg, arg.metavar}},
      else: bind_args(rest, [], acc)
  end

  defp bind_args([arg | rest], [value | values], acc) do
    bind_args(rest, values, Map.put(acc, arg.name, value))
  end

  defp help_style(:help_short), do: :short
  defp help_style(:help_long), do: :long

  defp find_flag(flags, long: name), do: Enum.find(flags, &(&1.long == name))
  defp find_flag(flags, short: letter), do: Enum.find(flags, &(&1.short == letter))

  defp split_long(token) do
    body = String.trim_leading(token, "--")

    case String.split(body, "=", parts: 2) do
      [name] -> {name, nil}
      [name, value] -> {name, value}
    end
  end

  defp flag_like?(token) when byte_size(token) > 1,
    do: String.starts_with?(token, "-") and not number_value?(token)

  defp flag_like?(_), do: false

  defp long?(token), do: String.starts_with?(token, "--")

  defp short_bundle?(token),
    do: String.starts_with?(token, "-") and not String.starts_with?(token, "--") and token != "-"

  defp number_value?("-" <> rest) when rest != "",
    do: Regex.match?(~r/^\d+(\.\d+)?([eE][+-]?\d+)?$/, rest)

  defp number_value?(_), do: false

  defp truthy_env?(raw), do: raw in ["1", "true", "True", "TRUE"]
end
