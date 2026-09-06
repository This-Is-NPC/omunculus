defmodule Omunculus.Runner do
  @moduledoc false

  alias Omunculus.CLI.Reporter
  alias Omunculus.{Agent, Auth, Chat, Config, FS}

  def start(args, flags, env \\ %{}) do
    with {:ok, cwd} <- canonicalize(args.dir),
         {:ok, config} <-
           Config.load(cwd: cwd, config_file: flags["config"] || flags[:config], env: env),
         {:ok, session} <- Config.resolve(config, flags),
         {:ok, chat} <- build_chat(session.chat, flags, env),
         fs <- FS.Disk.new(cwd),
         {:ok, reporter} <-
           Reporter.start_link(
             model: chat.model,
             tools: session.tools,
             max_rounds: session.max_turns,
             root: cwd,
             verbose?: flags["verbose"] || flags[:verbose] || false,
             json_events?: flags["json_events"] || flags[:json_events] || false,
             timestamp_format: session.output.timestamp_format
           ) do
      Agent.run(
        instruction: args.instruction,
        chat: chat,
        fs: fs,
        tools: session.tools,
        max_turns: session.max_turns,
        instructions: session.instructions,
        tool_options: flags[:tool_options] || %{},
        reporter: &Reporter.event(reporter, &1)
      )
    end
  end

  defp canonicalize(dir) when is_binary(dir) do
    expanded = Path.expand(dir)

    case File.stat(expanded) do
      {:ok, %{type: :directory}} ->
        case File.lstat(expanded) do
          {:ok, %{type: :symlink}} -> {:error, {:path_escape, dir}}
          {:ok, _} -> {:ok, expanded}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        {:error, {:usage, {:unexpected_arg, dir}}}

      {:error, :enoent} ->
        {:error, {:usage, {:missing_required_arg, "dir"}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_chat(chat_cfg, flags, env) do
    api = chat_cfg.api || "openai-completions"
    auth_type = chat_cfg.auth || infer_auth(chat_cfg, flags, env)

    base_url =
      flags["base_url"] || flags[:base_url] || chat_cfg.base_url || env["OMUNCULUS_BASE_URL"]

    model = flags["model"] || flags[:model] || chat_cfg.model || env["OMUNCULUS_MODEL"]

    api_key =
      flags["api_key"] || flags[:api_key] || chat_cfg.api_key || env["OMUNCULUS_API_KEY"] || ""

    cond do
      is_nil(base_url) or base_url == "" ->
        {:error, {:missing_base_url, nil}}

      is_nil(model) or model == "" ->
        {:error, {:missing_model, nil}}

      true ->
        with {:ok, chat_mod} <- Chat.resolve(api),
             {:ok, {auth_mod, cred}} <- Auth.resolve(auth_type) do
          cred = Map.put(cred, :key, api_key)
          {:ok, chat_mod.new(base_url: base_url, model: model, auth: {auth_mod, cred})}
        end
    end
  end

  defp infer_auth(chat_cfg, flags, env) do
    key = flags["api_key"] || flags[:api_key] || chat_cfg.api_key || env["OMUNCULUS_API_KEY"]
    if is_binary(key) and key != "", do: "api_key", else: "none"
  end
end
