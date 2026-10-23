import { stripeWebhook } from "../_shared/logic.js";

const env = {
  SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
  SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  STRIPE_WEBHOOK_SECRET: Deno.env.get("STRIPE_WEBHOOK_SECRET"),
  STRIPE_CONNECT_WEBHOOK_SECRET: Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET"),
  STRIPE_SECRET_KEY: Deno.env.get("STRIPE_SECRET_KEY"),
};

Deno.serve((req) => stripeWebhook(req, { env }));
