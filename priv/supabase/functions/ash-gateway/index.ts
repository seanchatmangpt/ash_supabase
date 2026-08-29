// ash-gateway: the one Supabase Edge Function every write in this
// project ever goes through.
//
// Copy this file to `supabase/functions/ash-gateway/index.ts` in your
// own Supabase project and deploy it (`supabase functions deploy
// ash-gateway`) alongside setting the `ASH_GATEWAY_URL` secret to your
// Ash application's `AshSupabase.Gateway` endpoint
// (`supabase secrets set ASH_GATEWAY_URL=https://your-ash-app/functions/v1/ash-gateway`).
//
// It does nothing resource-specific -- it never needs regenerating when
// you add a resource or action, unlike the TypeScript client
// (`mix ash_supabase.gen_client`) that calls it. Its only job is: take
// the request body and Authorization header a Supabase client sent,
// forward them verbatim to Ash, and return Ash's JSON response
// verbatim. Every actual authorization decision, every actual write,
// every actual dual-table event -- all of that happens on the Ash side
// (`AshSupabase.Gateway`), never here.
//
// A client that only speaks Supabase reaches this function via
// `supabase.functions.invoke("ash-gateway", { body: { resource, action,
// params } })` -- normally indirectly, through one of the typed
// functions in the generated client (`createTodo`, `updateTodo`, ...),
// never by constructing this request by hand.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const ASH_GATEWAY_URL = Deno.env.get("ASH_GATEWAY_URL");

serve(async (req: Request) => {
  if (!ASH_GATEWAY_URL) {
    return new Response(
      JSON.stringify({
        error: {
          type: "misconfigured",
          message: "ASH_GATEWAY_URL is not set for this Edge Function",
        },
      }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: { type: "not_found", message: "POST only" } }),
      { status: 404, headers: { "content-type": "application/json" } },
    );
  }

  const authorization = req.headers.get("authorization") ?? "";
  const body = await req.text();

  const ashResponse = await fetch(ASH_GATEWAY_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization,
    },
    body,
  });

  const responseBody = await ashResponse.text();

  return new Response(responseBody, {
    status: ashResponse.status,
    headers: { "content-type": "application/json" },
  });
});
