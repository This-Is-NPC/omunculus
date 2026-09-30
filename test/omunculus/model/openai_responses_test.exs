defmodule Omunculus.Model.OpenAIResponsesTest do
  use Omunculus.HttpModelCase, module: Omunculus.Model.OpenAIResponses, error: :openai

  for stream <- [false, true] do
    test "records all model turns and executes tools (stream: #{stream})", %{
      stub: stub,
      base_url: base_url
    } do
      :ok = OpenAIStub.configure(stub, tool_rounds: 1)
      events = run_counter("openai-responses", base_url, unquote(stream))

      assert Enum.map(events, & &1.type) == ~w(start-run tool model tool model end-run)
      [first, last] = Enum.filter(events, &(&1.type == "model"))
      assert Jason.decode!(first.body)["output"] != []
      assert Jason.decode!(last.body)["output"] != []
    end
  end
end
