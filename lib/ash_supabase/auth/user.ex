defmodule AshSupabase.Auth.Timestamp do
  @moduledoc false
  # GoTrue timestamps are RFC 3339 with a variable-precision fractional part
  # ("2026-09-06T11:59:00Z", "2021-02-17T04:43:32.770206+00:00"). Decoding is
  # deliberately lossless-on-failure: a value we cannot parse is handed back
  # verbatim so that a server-side format change surfaces as odd data rather
  # than as a crash in the middle of a sign-in.

  @spec parse(term()) :: DateTime.t() | String.t() | nil
  def parse(nil), do: nil
  def parse(""), do: nil
  def parse(%DateTime{} = datetime), do: datetime

  def parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> value
    end
  end

  def parse(value), do: value

  @spec from_unix(term()) :: DateTime.t() | nil
  def from_unix(nil), do: nil
  def from_unix(%DateTime{} = datetime), do: datetime

  def from_unix(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  def from_unix(seconds) when is_float(seconds), do: from_unix(trunc(seconds))
  def from_unix(_other), do: nil
end

defmodule AshSupabase.Auth.Identity do
  @moduledoc """
  One linked login method on a Supabase user.

  A user has an identity per provider they have signed in with, so a person who
  signed up with a password and later linked Google has two: one with
  `provider: "email"` and one with `provider: "google"`. `identity_data` is the
  raw profile the provider returned, which is where you find things like the
  Google `sub` or the avatar URL.

      iex> AshSupabase.Auth.Identity.from_json(%{
      ...>   "provider" => "email",
      ...>   "created_at" => "2026-09-06T11:59:00Z"
      ...> }).created_at
      ~U[2026-09-06 11:59:00Z]
  """

  alias AshSupabase.Auth.Timestamp

  @typedoc "A linked identity as returned inside `user.identities`."
  @type t :: %__MODULE__{
          identity_id: String.t() | nil,
          id: String.t() | nil,
          user_id: String.t() | nil,
          identity_data: map(),
          provider: String.t() | nil,
          last_sign_in_at: DateTime.t() | String.t() | nil,
          created_at: DateTime.t() | String.t() | nil,
          updated_at: DateTime.t() | String.t() | nil,
          email: String.t() | nil
        }

  defstruct [
    :identity_id,
    :id,
    :user_id,
    :provider,
    :last_sign_in_at,
    :created_at,
    :updated_at,
    :email,
    identity_data: %{}
  ]

  @doc """
  Builds an identity from its decoded JSON representation.

  Missing keys are tolerated; timestamps that cannot be parsed are kept as the
  raw string rather than raising.
  """
  @spec from_json(map() | t()) :: t()
  def from_json(%__MODULE__{} = identity), do: identity

  def from_json(json) when is_map(json) do
    %__MODULE__{
      identity_id: json["identity_id"],
      id: json["id"],
      user_id: json["user_id"],
      identity_data: json["identity_data"] || %{},
      provider: json["provider"],
      last_sign_in_at: Timestamp.parse(json["last_sign_in_at"]),
      created_at: Timestamp.parse(json["created_at"]),
      updated_at: Timestamp.parse(json["updated_at"]),
      email: json["email"]
    }
  end
end

defmodule AshSupabase.Auth.Factor do
  @moduledoc """
  A multi-factor authentication factor enrolled on a Supabase user.

  Only factors with `status: "verified"` can raise a session's assurance level
  to `aal2`, so checking `status` is what gates an MFA-protected action.
  """

  alias AshSupabase.Auth.Timestamp

  @typedoc "An MFA factor as returned inside `user.factors`."
  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: String.t() | nil,
          friendly_name: String.t() | nil,
          factor_type: String.t() | nil,
          webauthn_credential: String.t() | nil,
          phone: String.t() | nil,
          created_at: DateTime.t() | String.t() | nil,
          updated_at: DateTime.t() | String.t() | nil,
          last_challenged_at: DateTime.t() | String.t() | nil
        }

  defstruct [
    :id,
    :status,
    :friendly_name,
    :factor_type,
    :webauthn_credential,
    :phone,
    :created_at,
    :updated_at,
    :last_challenged_at
  ]

  @doc "Builds a factor from its decoded JSON representation."
  @spec from_json(map() | t()) :: t()
  def from_json(%__MODULE__{} = factor), do: factor

  def from_json(json) when is_map(json) do
    %__MODULE__{
      id: json["id"],
      status: json["status"],
      friendly_name: json["friendly_name"],
      factor_type: json["factor_type"],
      webauthn_credential: json["webauthn_credential"],
      phone: json["phone"],
      created_at: Timestamp.parse(json["created_at"]),
      updated_at: Timestamp.parse(json["updated_at"]),
      last_challenged_at: Timestamp.parse(json["last_challenged_at"])
    }
  end
end

defmodule AshSupabase.Auth.User do
  @moduledoc """
  A Supabase Auth (GoTrue) user.

  This is the `user` object returned by `GET /auth/v1/user`, nested inside every
  `AshSupabase.Auth.Session`, and returned by the admin endpoints. It carries
  every field GoTrue documents, so nothing is silently dropped, and every
  timestamp is decoded into a `DateTime`.

  Two metadata bags matter and they are not interchangeable:

    * `user_metadata` is writable by the user themselves (through
      `AshSupabase.Auth.update_user/3`, whose `data` key writes here), so it must
      **never** be trusted for authorization.
    * `app_metadata` is writable only with the service role key, which is what
      makes it the right place for roles, tenant ids, and plan levels that Row
      Level Security policies read back out of `auth.jwt()`.

  ## Example

      iex> user = AshSupabase.Auth.User.from_json(%{
      ...>   "id" => "123e4567-e89b-12d3-a456-426614174000",
      ...>   "email" => "user@example.com",
      ...>   "app_metadata" => %{"provider" => "email"},
      ...>   "created_at" => "2026-09-06T11:59:00Z",
      ...>   "is_anonymous" => false
      ...> })
      iex> {user.email, user.created_at}
      {"user@example.com", ~U[2026-09-06 11:59:00Z]}
  """

  alias AshSupabase.Auth.Factor
  alias AshSupabase.Auth.Identity
  alias AshSupabase.Auth.Timestamp

  @typedoc """
  A GoTrue user.

  Timestamp fields hold a `DateTime` when the server sent a parseable value, the
  raw `String` when it did not, and `nil` when the field was absent or JSON
  `null`.
  """
  @type t :: %__MODULE__{
          id: String.t() | nil,
          aud: String.t() | nil,
          role: String.t() | nil,
          email: String.t() | nil,
          email_confirmed_at: DateTime.t() | String.t() | nil,
          invited_at: DateTime.t() | String.t() | nil,
          phone: String.t() | nil,
          phone_confirmed_at: DateTime.t() | String.t() | nil,
          confirmation_sent_at: DateTime.t() | String.t() | nil,
          confirmed_at: DateTime.t() | String.t() | nil,
          recovery_sent_at: DateTime.t() | String.t() | nil,
          new_email: String.t() | nil,
          email_change_sent_at: DateTime.t() | String.t() | nil,
          new_phone: String.t() | nil,
          phone_change_sent_at: DateTime.t() | String.t() | nil,
          reauthentication_sent_at: DateTime.t() | String.t() | nil,
          last_sign_in_at: DateTime.t() | String.t() | nil,
          app_metadata: map(),
          user_metadata: map(),
          factors: [Factor.t()],
          identities: [Identity.t()],
          created_at: DateTime.t() | String.t() | nil,
          updated_at: DateTime.t() | String.t() | nil,
          banned_until: DateTime.t() | String.t() | nil,
          deleted_at: DateTime.t() | String.t() | nil,
          is_anonymous: boolean()
        }

  defstruct [
    :id,
    :aud,
    :role,
    :email,
    :email_confirmed_at,
    :invited_at,
    :phone,
    :phone_confirmed_at,
    :confirmation_sent_at,
    :confirmed_at,
    :recovery_sent_at,
    :new_email,
    :email_change_sent_at,
    :new_phone,
    :phone_change_sent_at,
    :reauthentication_sent_at,
    :last_sign_in_at,
    :created_at,
    :updated_at,
    :banned_until,
    :deleted_at,
    app_metadata: %{},
    user_metadata: %{},
    factors: [],
    identities: [],
    is_anonymous: false
  ]

  @doc """
  Builds a user from its decoded JSON representation.

  Every key is optional: GoTrue omits `omitempty` fields entirely, and admin
  responses can include a subset. Unparseable timestamps are preserved verbatim
  so that a server-side format change degrades instead of crashing.
  """
  @spec from_json(map() | t()) :: t()
  def from_json(%__MODULE__{} = user), do: user

  def from_json(json) when is_map(json) do
    %__MODULE__{
      id: json["id"],
      aud: json["aud"],
      role: json["role"],
      email: json["email"],
      email_confirmed_at: Timestamp.parse(json["email_confirmed_at"]),
      invited_at: Timestamp.parse(json["invited_at"]),
      phone: json["phone"],
      phone_confirmed_at: Timestamp.parse(json["phone_confirmed_at"]),
      confirmation_sent_at: Timestamp.parse(json["confirmation_sent_at"]),
      confirmed_at: Timestamp.parse(json["confirmed_at"]),
      recovery_sent_at: Timestamp.parse(json["recovery_sent_at"]),
      new_email: json["new_email"],
      email_change_sent_at: Timestamp.parse(json["email_change_sent_at"]),
      new_phone: json["new_phone"],
      phone_change_sent_at: Timestamp.parse(json["phone_change_sent_at"]),
      reauthentication_sent_at: Timestamp.parse(json["reauthentication_sent_at"]),
      last_sign_in_at: Timestamp.parse(json["last_sign_in_at"]),
      app_metadata: json["app_metadata"] || %{},
      user_metadata: json["user_metadata"] || %{},
      factors: Enum.map(json["factors"] || [], &Factor.from_json/1),
      identities: Enum.map(json["identities"] || [], &Identity.from_json/1),
      created_at: Timestamp.parse(json["created_at"]),
      updated_at: Timestamp.parse(json["updated_at"]),
      banned_until: Timestamp.parse(json["banned_until"]),
      deleted_at: Timestamp.parse(json["deleted_at"]),
      is_anonymous: json["is_anonymous"] || false
    }
  end

  @doc """
  Returns `true` while the user is banned.

  GoTrue keeps returning a banned user from the admin API, and `banned_until`
  can be in the past once a temporary ban has lapsed, so the timestamp alone is
  not the answer.

      iex> AshSupabase.Auth.User.banned?(%AshSupabase.Auth.User{})
      false
  """
  @spec banned?(t(), DateTime.t()) :: boolean()
  def banned?(user, now \\ DateTime.utc_now())

  def banned?(%__MODULE__{banned_until: %DateTime{} = until}, %DateTime{} = now),
    do: DateTime.compare(until, now) == :gt

  def banned?(%__MODULE__{}, %DateTime{}), do: false

  @doc """
  Returns the identity for `provider`, or `nil`.

      iex> AshSupabase.Auth.User.identity(%AshSupabase.Auth.User{}, "google")
      nil
  """
  @spec identity(t(), String.t()) :: Identity.t() | nil
  def identity(%__MODULE__{identities: identities}, provider) when is_binary(provider) do
    Enum.find(identities, &(&1.provider == provider))
  end
end
