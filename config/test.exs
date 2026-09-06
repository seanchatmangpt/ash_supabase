import Config

config :logger, level: :warning

# Every test stubs HTTP with `Req.Test`, so a request that escapes the stub
# should fail loudly rather than reach the network.
config :ash_supabase, :req_test_mode, :private
