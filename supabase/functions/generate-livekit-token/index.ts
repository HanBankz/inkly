import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { AccessToken } from "https://esm.sh/livekit-server-sdk@2.7.2";

serve(async (req) => {
  const { room, identity, name } = await req.json();

  const apiKey = Deno.env.get("LIVEKIT_API_KEY")!;
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET")!;

  const token = new AccessToken(apiKey, apiSecret, {
    identity: identity,
    name: name,
  });

  token.addGrant({
    room: room,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
  });

  const jwt = await token.toJwt();

  return new Response(JSON.stringify({ token: jwt }), {
    headers: { "Content-Type": "application/json" },
  });
});