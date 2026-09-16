defmodule Omunculus.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Omunculus.Execution.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Omunculus.Execution.Limiter.Supervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Omunculus.Execution.ProcessSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Omunculus.Supervisor)
  end
end
