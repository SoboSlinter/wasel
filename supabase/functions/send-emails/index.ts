import { sendEmails } from "../_shared/email.js";

const env = {
  SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
  SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  SITE_URL: Deno.env.get("SITE_URL"),
  RESEND_API_KEY: Deno.env.get("RESEND_API_KEY"),
  EMAIL_FROM: Deno.env.get("EMAIL_FROM"),
  EMAIL_CRON_SECRET: Deno.env.get("EMAIL_CRON_SECRET"),
};
async function getUser(token) {
  const r = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { apikey: env.SERVICE_KEY, authorization: `Bearer ${token}` } });
  return r.ok ? await r.json() : null;
}
Deno.serve((req) => sendEmails(req, { env, getUser }));
