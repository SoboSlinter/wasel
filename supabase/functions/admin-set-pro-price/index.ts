import { setProPrice } from "../_shared/logic.js";

const env = {
  SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
  SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  STRIPE_SECRET_KEY: Deno.env.get("STRIPE_SECRET_KEY"),
  SITE_URL: Deno.env.get("SITE_URL"),
};
async function getUser(token) {
  const r = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { apikey: env.SERVICE_KEY, authorization: `Bearer ${token}` } });
  return r.ok ? await r.json() : null;
}
Deno.serve((req) => setProPrice(req, { env, getUser }));
