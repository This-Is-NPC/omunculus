defmodule Omunculus.Chat do
  @moduledoc false

  @type message :: map()
  @type result :: %{content: term(), tool_calls: [map()] | nil, usage: map() | nil}

  @callback complete(t, [message()], [map()]) :: {:ok, result()} | {:error, term()}
            when t: map()

  def resolve("openai-completions"), do: {:ok, Omunculus.Chat.Completions}
  def resolve("fake"), do: {:ok, Omunculus.Chat.Fake}
  def resolve("openai-responses"), do: {:error, {:unsupported_api, "openai-responses"}}

  def resolve("openai-codex-responses"),
    do: {:error, {:unsupported_api, "openai-codex-responses"}}

  def resolve("anthropic-messages"), do: {:error, {:unsupported_api, "anthropic-messages"}}
  def resolve(other) when is_binary(other), do: {:error, {:unsupported_api, other}}
  def resolve(nil), do: resolve("openai-completions")

  def complete(%{mod: mod} = chat, messages, tools), do: mod.complete(chat, messages, tools)
end
