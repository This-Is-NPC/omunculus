import Config

config :omunculus, :chat_timeout_ms, 120_000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
