defmodule Omunculus.Server.Auth do
  @moduledoc "Verifies a signed bearer token and returns its stable principal."

  @spec load(map) :: {:ok, map} | {:error, term}
  def load(config) do
    try do
      {:ok, Map.put(config, :jwk, JOSE.JWK.from_pem_file(config.public_key))}
    rescue
      _ -> {:error, {:server, :invalid_public_key}}
    end
  end

  @spec verify(map, String.t()) :: {:ok, map} | {:error, :unauthorized}
  def verify(config, token) do
    try do
      case JOSE.JWT.verify_strict(config.jwk, [config.algorithm], token) do
        {true, %{fields: claims}, _jws} -> validate(config, claims)
        _ -> {:error, :unauthorized}
      end
    rescue
      _ -> {:error, :unauthorized}
    catch
      _, _ -> {:error, :unauthorized}
    end
  end

  defp validate(config, claims) do
    now = System.system_time(:second)
    audience = claims["aud"]

    if claims["iss"] == config.issuer and
         (audience == config.audience or
            (is_list(audience) and config.audience in audience)) and
         is_integer(claims["exp"]) and claims["exp"] > now and
         (is_nil(claims["nbf"]) or (is_integer(claims["nbf"]) and claims["nbf"] <= now)) and
         is_binary(claims["sub"]) and claims["sub"] != "" do
      {:ok, %{issuer: config.issuer, subject: claims["sub"]}}
    else
      {:error, :unauthorized}
    end
  end
end
