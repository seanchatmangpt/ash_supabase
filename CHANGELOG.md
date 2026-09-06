# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-06

Initial release.

### Added

- `AshSupabase.DataLayer` — an `Ash.DataLayer` backed by the Supabase Data API
  (PostgREST). Pushes filters, sorts, `limit`/`offset`, column selection,
  upserts, bulk creates and bulk updates/destroys down into a single request,
  and serves `count` from the `Content-Range` header. Reports its real
  capabilities through `can?/2` so Ash plans around what PostgREST cannot do.
- `AshSupabase.PostgREST` — a standalone Data API client: `run`, `insert`,
  `update`, `delete` and `rpc`, with a guardrail that refuses an unfiltered
  `PATCH` or `DELETE` unless asked explicitly.
- `AshSupabase.PostgREST.Filter` — translates `Ash.Filter` expressions into
  PostgREST query parameters, including nested logical groups and De Morgan
  normalization of negation.
- `AshSupabase.PostgREST.Encoder` — PostgREST value encoding: reserved-character
  quoting, `in` lists, array literals, and `LIKE` pattern escaping.
- `AshSupabase.Client` / `AshSupabase.Config` — a configurable client module per
  project, with per-request token and schema overrides and redacted secrets.
- `AshSupabase.Auth` — the GoTrue API, including the service-role admin
  endpoints in `AshSupabase.Auth.Admin`.
- `AshSupabase.Auth.JWT` — local access-token verification for both the legacy
  HS256 secret and current asymmetric keys, with a caching JWKS client that
  handles key rotation.
- `AshSupabase.Plug` — verifies the bearer token and assigns the claims and
  current user.
- `AshSupabase.Storage` — buckets and objects, signed URLs and signed uploads.
- `AshSupabase.Realtime` — `postgres_changes` subscriptions over the Phoenix
  Channels protocol.
- `AshSupabase.Rls` — request-scoped JWT claims for `AshPostgres`, so RLS
  policies calling `auth.uid()` work over a direct database connection.
- `mix ash_supabase.install` and `mix ash_supabase.gen.resource` installers.

[0.1.0]: https://github.com/seanchatmangpt/ash_supabase/releases/tag/v0.1.0
