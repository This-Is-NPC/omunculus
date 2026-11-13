defmodule Omunculus.Jobs.Notice do
  @moduledoc """
  Tells a job's owner something happened to it: a late fire, a job paused or
  ended. The notice is a request from the owner to the owner, in the job's
  conversation when it has one, so it waits among the owner's pending
  requests like any question; the scheduler is not a run, so the inbox of a
  run is no way to reach a person.
  """

  alias Omunculus.Store.{Events, Query}
  alias Omunculus.Store.Actions.Requests

  @doc "Opens a request about `job` to its owner, saying `text`."
  @spec owner(Omunculus.Store.Connection.t(), map, String.t()) :: :ok | {:error, term}
  def owner(conn, %{"owner" => owner} = job, text) when is_map(owner) do
    ctx = %{
      run_id: nil,
      work_id: nil,
      author: "harness",
      agent: nil,
      issuer: nil,
      subject: nil,
      conversation_id: job["conversation_id"],
      request_id: nil
    }

    Events.with_actor(conn, ctx, fn ->
      Query.transaction(conn, fn ->
        with {:ok, _event} <-
               Requests.create(
                 conn,
                 ctx,
                 nil,
                 nil,
                 owner,
                 "Job #{job["name"]}: #{text}",
                 %{},
                 owner,
                 nil,
                 false
               ),
             do: {:ok, :noticed}
      end)
    end)
    |> case do
      {:ok, :noticed} -> :ok
      error -> error
    end
  end

  def owner(_conn, _job, _text), do: :ok
end
