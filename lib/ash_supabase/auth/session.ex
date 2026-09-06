defmodule AshSupabase.Auth.Session do
  @moduledoc """
  A Supabase Auth session — GoTrue's `AccessTokenResponse`.

  This is what every successful credential exchange returns: `/signup` (when
  email confirmation is off), `/token` for all grant types, and `/verify`. The
  `access_token` is the JWT you hand back to `AshSupabase.Client` as `:token` so
  that PostgREST evaluates Row Level Security as that user; the `refresh_token`
  is single-use and is exchanged through `AshSupabase.Auth.refresh_session/2`.

  ## Expiry

  GoTrue sends both `expires_in` (seconds from issue) and `expires_at` (an
  absolute unix timestamp). Only `expires_at` survives being stored in a
  database or a cookie, so that is the one `expired?/2` uses, decoded into a
  `DateTime`:

      iex> session = AshSupabase.Auth.Session.from_json(%{
      ...>   "access_token" => "jwt", "expires_at" => 1_757_753_066
      ...> })
      iex> AshSupabase.Auth.Session.expired?(session, ~U[2025-09-13 08:00:00Z])
      false

  ## Redaction

  The struct implements `Inspect` so that neither the access token, the refresh
  token, nor OAuth provider tokens can reach a log line or a crash report.
  """

  alias AshSupabase.Auth.Timestamp
  alias AshSupabase.Auth.User

  @typedoc """
  The weak-password advisory GoTrue attaches to a successful password sign-in.

  Reasons are drawn from `"length"`, `"characters"` and `"pwned"`. Its presence
  means the sign-in succeeded but the password should be changed.
  """
  @type weak_password :: %{optional(String.t()) => term()}

  @typedoc "A signed-in session."
  @type t :: %__MODULE__{
          access_token: String.t() | nil,
          token_type: String.t() | nil,
          expires_in: integer() | nil,
          expires_at: DateTime.t() | nil,
          refresh_token: String.t() | nil,
          user: User.t() | nil,
          provider_token: String.t() | nil,
          provider_refresh_token: String.t() | nil,
          weak_password: weak_password() | nil
        }

  defstruct [
    :access_token,
    :token_type,
    :expires_in,
    :expires_at,
    :refresh_token,
    :user,
    :provider_token,
    :provider_refresh_token,
    :weak_password
  ]

  @doc """
  Builds a session from a decoded `AccessTokenResponse`.

  `expires_at` arrives as unix seconds and is converted to a `DateTime`;
  `user` is decoded into an `AshSupabase.Auth.User`. Absent keys stay `nil`,
  which is the normal case for `provider_token`, `provider_refresh_token` and
  `weak_password` — GoTrue marks all three `omitempty`.
  """
  @spec from_json(map() | t()) :: t()
  def from_json(%__MODULE__{} = session), do: session

  def from_json(json) when is_map(json) do
    %__MODULE__{
      access_token: json["access_token"],
      token_type: json["token_type"],
      expires_in: json["expires_in"],
      expires_at: Timestamp.from_unix(json["expires_at"]),
      refresh_token: json["refresh_token"],
      user: json["user"] && User.from_json(json["user"]),
      provider_token: json["provider_token"],
      provider_refresh_token: json["provider_refresh_token"],
      weak_password: json["weak_password"]
    }
  end

  @doc """
  Returns `true` when the access token is no longer valid at `now`.

  A session whose `expires_at` is missing is reported as expired. That is the
  safe direction: refreshing a session that did not need it costs one request,
  whereas trusting a session with an unknown expiry costs a rejected API call at
  an arbitrary later point.

      iex> alias AshSupabase.Auth.Session
      iex> Session.expired?(%Session{expires_at: ~U[2026-09-06 12:00:00Z]}, ~U[2026-09-06 13:00:00Z])
      true
      iex> Session.expired?(%Session{}, ~U[2026-09-06 13:00:00Z])
      true
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(session, now \\ DateTime.utc_now())

  def expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now),
    do: DateTime.compare(now, expires_at) != :lt

  def expired?(%__MODULE__{expires_at: nil}, %DateTime{}), do: true

  @doc """
  Seconds remaining before the access token expires, floored at zero.

      iex> alias AshSupabase.Auth.Session
      iex> Session.expires_in_seconds(%Session{expires_at: ~U[2026-09-06 12:00:00Z]}, ~U[2026-09-06 11:59:00Z])
      60
  """
  @spec expires_in_seconds(t(), DateTime.t()) :: non_neg_integer() | nil
  def expires_in_seconds(session, now \\ DateTime.utc_now())

  def expires_in_seconds(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now),
    do: max(DateTime.diff(expires_at, now, :second), 0)

  def expires_in_seconds(%__MODULE__{expires_at: nil}, %DateTime{}), do: nil

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(session, opts) do
      redacted = %{
        access_token: redact(session.access_token),
        token_type: session.token_type,
        expires_in: session.expires_in,
        expires_at: session.expires_at,
        refresh_token: redact(session.refresh_token),
        user: session.user,
        provider_token: redact(session.provider_token),
        provider_refresh_token: redact(session.provider_refresh_token),
        weak_password: session.weak_password
      }

      concat(["#AshSupabase.Auth.Session<", to_doc(redacted, opts), ">"])
    end

    defp redact(nil), do: nil
    defp redact(_value), do: "[REDACTED]"
  end
end
