defmodule Omunculus.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{DynamicSupervisor, strategy: :one_for_one, name: Omunculus.SessionExecutors}],
      strategy: :one_for_one,
      name: Omunculus.Supervisor
    )
  end
end
