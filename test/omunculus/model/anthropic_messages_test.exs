defmodule Omunculus.Model.AnthropicMessagesTest do
  use Omunculus.HttpModelCase, module: Omunculus.Model.AnthropicMessages, error: :anthropic

  for stream <- [false, true] do
    test "records all model turns and executes tools (stream: #{stream})", %{
      stub: stub,
      base_url: base_url
    } do
      :ok = OpenAIStub.configure(stub, tool_rounds: 1)
      events = run_counter("anthropic-messages", base_url, unquote(stream))

      assert Enum.map(events, & &1.type) == ~w(start-run tool model tool model end-run)
      [first, last] = Enum.filter(events, &(&1.type == "model"))
      assert Jason.decode!(first.body)["content"] != []
      assert Jason.decode!(last.body)["content"] != []
    end
  end
end
