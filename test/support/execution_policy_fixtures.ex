defmodule Omunculus.ExecutionPolicyFixtures do
  @moduledoc false

  alias Omunculus.Execution.Policy

  def policy(roots, options \\ []) do
    roots = List.wrap(roots)
    writable? = Keyword.get(options, :writable, false)

    read_only = Keyword.get(options, :read_only, if(writable?, do: [], else: roots))
    read_write = Keyword.get(options, :read_write, if(writable?, do: roots, else: []))

    %Policy{
      id: "test-policy",
      workspace: %{name: nil, root: List.first(roots)},
      read_only: read_only,
      read_write: read_write,
      hidden: Keyword.get(options, :hidden, []),
      runtimes: ["/usr"],
      backend: "bubblewrap",
      environment: %{"LANG" => "C"},
      network: Keyword.get(options, :network, "host"),
      limits:
        Map.merge(
          %{
            timeout_ms: 2_000,
            max_output_bytes: 1_024,
            max_concurrent: 64,
            max_queue: 1,
            queue_timeout_ms: 100
          },
          Keyword.get(options, :limits, %{})
        ),
      tools: []
    }
  end
end
