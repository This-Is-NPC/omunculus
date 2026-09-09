defmodule Omunculus.AgentFile do
  @moduledoc "Agent Markdown files with TOML frontmatter and a role prompt as their body."
  @fields ~w(tools prompt kind max_retries workflow root_approval model max_turns)a

  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, agent} <- decode(text) do
      {:ok, agent}
    else
      {:error, reason} -> {:error, {:invalid_agent_file, path, reason}}
    end
  end

  def decode(text) do
    case Regex.run(~r/\A\+\+\+\r?\n(.*?)^\+\+\+\r?\n(.*)\z/ms, text) do
      [_, header, body] ->
        with {:ok, metadata} <- Toml.decode(header),
             :ok <- validate(metadata),
             prompt when prompt != "" <- String.trim(body) do
          {:ok, Map.put(metadata, "prompt", prompt)}
        else
          "" -> {:error, :empty_prompt}
          {:error, _} = error -> error
        end

      _ ->
        {:error, :expected_toml_frontmatter}
    end
  end

  def normalize(body) do
    Map.new(@fields, &{&1, body[Atom.to_string(&1)]})
  end

  def merge(base, overlay),
    do: Map.merge(base, Map.reject(overlay, fn {_, value} -> is_nil(value) end))

  defp validate(metadata) do
    Enum.reduce_while(metadata, :ok, fn {key, value}, :ok ->
      valid =
        case key do
          key when key in ["kind", "model"] -> is_binary(value) and String.trim(value) != ""
          "max_turns" -> is_integer(value) and value > 0
          "max_retries" -> is_integer(value) and value >= 0
          "workflow" -> value == false or (is_binary(value) and value != "")
          "root_approval" -> value in ["self", "human"]
          _ -> false
        end

      if valid, do: {:cont, :ok}, else: {:halt, {:error, {:invalid_frontmatter_field, key}}}
    end)
  end
end
