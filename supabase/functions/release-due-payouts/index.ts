import { releaseDuePayouts } from "../_shared/logic.js";

const env = {
  SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
  SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  STRIPE_SECRET_KEY: Deno.env.get("STRIPE_SECRET_KEY"),
  CRON_SECRET: Deno.env.get("CRON_SECRET"),
  EMAIL_CRON_SECRET: Deno.env.get("EMAIL_CRON_SECRET"),
};
Deno.serve((req) => releaseDuePayouts(req, { env }));
