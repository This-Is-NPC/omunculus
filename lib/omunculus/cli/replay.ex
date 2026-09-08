defmodule Omunculus.CLI.Replay do
  @moduledoc "Read a fixed SQLite snapshot without starting any execution machinery."
  alias Exqlite.Sqlite3
  alias Omunculus.EventCore.Store
  alias Omunculus.Event.Envelope
  alias Omunculus.CLI.{Reporter, Session}

  def run(session_id, flags) do
    {:ok, path} = Session.db_path(flags)

    case read(
           path,
           session_id,
           fn event -> Reporter.event(Process.get(:replay_reporter), event) end,
           fn ->
             {:ok, pid} =
               Reporter.start_link(io: :stdio, mode: "Replay", path: path, session_id: session_id)

             Process.put(:replay_reporter, pid)
           end
         ) do
      :ok ->
        0

      {:error, reason} ->
        IO.puts(:stderr, "error: replay: #{inspect(reason)}")
        1
    end
  after
    if pid = Process.delete(:replay_reporter), do: Reporter.finish(pid)
  end

  def read(path, session_id, consume, on_open \\ fn -> :ok end) do
    with {:ok, conn} <- Sqlite3.open(path, mode: :readonly) do
      try do
        Store.exec!(conn, "BEGIN")

        unless Store.one(
                 conn,
                 "SELECT 1 FROM EVENTS WHERE session_id = ? AND type = 'session.created' LIMIT 1",
                 [session_id]
               ),
               do: raise("unknown session: #{session_id}")

        [[limit]] =
          Store.query(
            conn,
            "SELECT COALESCE(MAX(sequence), 0) FROM EVENTS WHERE session_id = ?",
            [session_id]
          )

        on_open.()
        stream(conn, session_id, 0, limit, consume)
      rescue
        error -> {:error, Exception.message(error)}
      after
        Sqlite3.close(conn)
      end
    end
  end

  defp stream(conn, session_id, cursor, limit, consume) do
    columns = Enum.join(Envelope.columns(), ",")

    rows =
      Store.query(
        conn,
        "SELECT #{columns} FROM EVENTS WHERE session_id = ? AND sequence > ? AND sequence <= ? ORDER BY sequence LIMIT 256",
        [session_id, cursor, limit]
      )

    events = Enum.map(rows, &Envelope.from_row/1)

    for event <- events do
      if event.schema_version != "1",
        do: raise("unsupported event schema #{event.schema_version}")

      consume.(event)
    end

    case List.last(events) do
      nil -> :ok
      event -> stream(conn, session_id, event.sequence, limit, consume)
    end
  end
end
