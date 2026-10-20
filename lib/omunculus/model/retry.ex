defmodule Omunculus.Model.Retry do
  @moduledoc """
  How an HTTP model adapter retries a request: a model's `retries` in
  `[models.<name>]` sends it again that many times on a rate limit (429),
  a timeout (408) or a server error (500, 502, 503, 504) or a dropped
  connection, after the delay the server's `Retry-After` asks for, or a
  growing one; without `retries`, a failed request fails the call.
  """

  @spec options(non_neg_integer | nil) :: keyword
  def options(nil), do: [retry: false]
  def options(retries), do: [retry: :transient, max_retries: retries]
end
