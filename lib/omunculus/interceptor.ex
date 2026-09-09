defmodule Omunculus.Interceptor do
  @moduledoc """
  Behaviour for native policy gates (the `module` config selector).
  Agent and external actor exchanges use Omunculus.Interception, outside this callback.

  A native gate runs inside the Event Core, synchronously, after commit and
  before delivery, only for the event types it is configured for. It may let
  the envelope through or reject its delivery; it never rewrites the envelope
  and never appends. A rejection is recorded by the Core as
  `delivery.rejected`.
  """

  alias Omunculus.Event.Envelope

  @callback intercept(Envelope.t(), options :: map()) :: :deliver | {:reject, term()}

  @doc "Resolve a configured module name to a loaded module implementing this behaviour."
  def resolve(name) when is_binary(name) do
    module = Module.concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, :intercept, 2),
      do: {:ok, module},
      else: {:error, {:unknown_interceptor_module, name}}
  end
end
