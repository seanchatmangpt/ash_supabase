[
  # `Mint.HTTP.t()` is an opaque type, and `Mint.WebSocket.upgrade/4` takes it
  # as a union of the opaque HTTP1/HTTP2/UnsafeProxy structs. Dialyzer cannot
  # see through the union and reports the (correct, documented) call as passing
  # an opaque term. Upstream issue; nothing to fix on this side.
  {"lib/ash_supabase/realtime/socket.ex", :call_with_opaque}
]
