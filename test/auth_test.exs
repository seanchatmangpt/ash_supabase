defmodule AshSupabase.AuthTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Auth

  @secret "super-secret-supabase-jwt-secret"

  describe "verify/3 (HS256, Supabase's legacy shared-secret model)" do
    test "accepts a validly signed, unexpired token and builds an actor" do
      token =
        sign(%{
          "sub" => "11111111-1111-1111-1111-111111111111",
          "role" => "authenticated",
          "email" => "jane@example.com",
          "aud" => "authenticated",
          "exp" => future()
        })

      assert {:ok, actor} = Auth.verify(token, @secret)
      assert actor.id == "11111111-1111-1111-1111-111111111111"
      assert actor.role == "authenticated"
      assert actor.email == "jane@example.com"
      assert actor.claims["sub"] == actor.id
    end

    test "rejects a token signed with the wrong secret" do
      token = sign(%{"sub" => "u1", "aud" => "authenticated", "exp" => future()})

      assert {:error, :invalid_signature} = Auth.verify(token, "not-the-real-secret")
    end

    test "rejects a token whose payload was tampered with after signing" do
      token = sign(%{"sub" => "u1", "role" => "authenticated", "exp" => future()})
      [header, _payload, sig] = String.split(token, ".")

      forged_payload =
        %{"sub" => "u1", "role" => "service_role", "exp" => future()}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      forged = Enum.join([header, forged_payload, sig], ".")

      assert {:error, :invalid_signature} = Auth.verify(forged, @secret)
    end

    test "rejects an expired token" do
      token = sign(%{"sub" => "u1", "aud" => "authenticated", "exp" => past()})

      assert {:error, :expired} = Auth.verify(token, @secret)
    end

    test "rejects alg: none (and any alg other than HS256) outright" do
      header =
        %{"alg" => "none", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)

      payload =
        %{"sub" => "u1", "exp" => future()}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      token = "#{header}.#{payload}."

      assert {:error, {:unsupported_alg, "none"}} = Auth.verify(token, @secret)
    end

    test "rejects the default audience by default when the token has a different aud" do
      token = sign(%{"sub" => "u1", "aud" => "service_role", "exp" => future()})

      assert {:error, {:invalid_audience, _}} = Auth.verify(token, @secret)
    end

    test "skips the audience check when :audience is nil" do
      token = sign(%{"sub" => "u1", "aud" => "service_role", "exp" => future()})

      assert {:ok, %Auth.Actor{id: "u1"}} = Auth.verify(token, @secret, audience: nil)
    end

    test "defaults role to \"authenticated\" when the claim is absent" do
      token = sign(%{"sub" => "u1", "aud" => "authenticated", "exp" => future()})

      assert {:ok, %Auth.Actor{role: "authenticated"}} = Auth.verify(token, @secret)
    end
  end

  defp sign(claims) do
    header = %{"alg" => "HS256", "typ" => "JWT"} |> Jason.encode!() |> b64()
    payload = claims |> Jason.encode!() |> b64()
    signing_input = "#{header}.#{payload}"
    signature = :crypto.mac(:hmac, :sha256, @secret, signing_input) |> b64()
    "#{signing_input}.#{signature}"
  end

  defp b64(binary), do: Base.url_encode64(binary, padding: false)
  defp future, do: System.system_time(:second) + 3600
  defp past, do: System.system_time(:second) - 3600
end
