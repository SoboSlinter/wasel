// Pure logic, no Deno-only APIs, so it can be tested in Node.
const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

export const json = (obj, status = 200, headers = {}) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", ...headers } });

export async function hmacHex(secret, text) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(text)));
}

const safeEqual = (a, b) => {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
};

// Stripe-Signature: t=timestamp,v1=signature[,v1=...]   signed payload = `${t}.${rawBody}`
export async function verifyStripeSignature(rawBody, header, secret, nowSec = Math.floor(Date.now() / 1000), tolerance = 300) {
  if (!header || !secret) return false;
  const parts = header.split(",").map((p) => p.trim().split("="));
  const t = parts.find(([k]) => k === "t")?.[1];
  const sigs = parts.filter(([k]) => k === "v1").map(([, v]) => v);
  if (!t || !sigs.length || Math.abs(nowSec - Number(t)) > tolerance) return false;
  const expected = await hmacHex(secret, `${t}.${rawBody}`);
  return sigs.some((s) => safeEqual(s, expected));
}

const cors = (origin) => ({
  "access-control-allow-origin": origin || "*",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
});

async function rpc(env, fn, args, f) {
  const r = await f(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: env.SERVICE_KEY, authorization: `Bearer ${env.SERVICE_KEY}`, "content-type": "application/json" },
    body: JSON.stringify(args),
  });
  const body = await r.json().catch(() => null);
  if (!r.ok) throw Object.assign(new Error(body?.message || "Database error"), { status: r.status });
  return body;
}

// POST { booking_id }  (Authorization: user's Supabase JWT)  ->  { url }
export async function createCheckout(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);

  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const user = token ? await getUser(token) : null;
  if (!user) return json({ error: "Please sign in" }, 401, c);

  const { booking_id } = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/i.test(booking_id || "")) return json({ error: "Invalid booking" }, 400, c);

  let row;
  try {
    [row] = await rpc(env, "start_booking_payment", { p_booking_id: booking_id, p_customer_id: user.id }, f);
  } catch (e) {
    return json({ error: e.message }, 400, c);
  }

  const form = new URLSearchParams({
    mode: "payment",
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(Math.round(Number(row.amount) * 100)),
    "line_items[0][price_data][product_data][name]": row.service_name,
    success_url: `${env.SITE_URL}/bookings.html?paid=1`,
    cancel_url: `${env.SITE_URL}/bookings.html?pay_cancelled=1`,
    client_reference_id: booking_id,
    "metadata[booking_id]": booking_id,
  });
  if (user.email) form.set("customer_email", user.email);

  const sr = await f("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      "content-type": "application/x-www-form-urlencoded",
      "idempotency-key": `${row.payment_id}-${Math.round(Number(row.amount) * 100)}-${Date.now() >> 16}`,
    },
    body: form,
  });
  const session = await sr.json().catch(() => null);
  if (!sr.ok || !session?.url) return json({ error: "Could not start the payment" }, 502, c);

  await rpc(env, "attach_checkout_session", { p_payment_id: row.payment_id, p_session_id: session.id }, f);
  return json({ url: session.url }, 200, c);
}

async function stripeApi(env, f, method, path, form, idem) {
  const r = await f(`https://api.stripe.com/v1/${path}`, {
    method,
    headers: {
      authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      ...(form ? { "content-type": "application/x-www-form-urlencoded" } : {}),
      ...(idem ? { "idempotency-key": idem } : {}),
    },
    body: form ? new URLSearchParams(form) : undefined,
  });
  const body = await r.json().catch(() => null);
  if (!r.ok) throw new Error(body?.error?.message || "Stripe error");
  return body;
}

// Send the provider's share to their Stripe account. Safe to call many times:
// the database decides if it is allowed (paid + completed + account ready) and
// Stripe's idempotency key stops a double transfer.
export async function sendPayout(env, f, paymentId, caller = null) {
  const [c] = await rpc(env, "claim_payout", { p_payment_id: paymentId, p_caller: caller }, f);
  if (c.code !== "ok") return { status: c.code };
  try {
    const pi = await stripeApi(env, f, "GET", `payment_intents/${encodeURIComponent(c.payment_intent)}`);
    const charge = typeof pi.latest_charge === "string" ? pi.latest_charge : pi.latest_charge?.id;
    if (!charge) throw new Error("No charge found for this payment");
    const tr = await stripeApi(env, f, "POST", "transfers", {
      amount: String(Math.round(Number(c.amount) * 100)),
      currency: "usd",
      destination: c.account_id,
      source_transaction: charge,
      transfer_group: `booking_${c.booking_id}`,
      "metadata[booking_id]": c.booking_id,
      "metadata[payment_id]": paymentId,
    }, `payout-${paymentId}`);
    await rpc(env, "finish_payout", { p_payment_id: paymentId, p_transfer_id: tr.id }, f);
    return { status: "sent" };
  } catch (e) {
    await rpc(env, "fail_payout", { p_payment_id: paymentId }, f).catch(() => {});
    return { status: "failed" };
  }
}

// Give the customer their money back after a cancelled booking. Safe to call many times:
// the database decides if it is allowed and Stripe's idempotency key stops a double refund.
export async function sendRefund(env, f, paymentId, caller = null) {
  const [c] = await rpc(env, "claim_refund", { p_payment_id: paymentId, p_caller: caller }, f);
  if (c.code !== "ok") return { status: c.code };
  try {
    const rf = await stripeApi(env, f, "POST", "refunds", {
      payment_intent: c.payment_intent,
      reason: "requested_by_customer",
      "metadata[booking_id]": c.booking_id,
      "metadata[payment_id]": paymentId,
    }, `refund-${paymentId}`);
    await rpc(env, "finish_refund", { p_payment_id: paymentId, p_refund_id: rf.id }, f);
    return { status: "refunded" };
  } catch (e) {
    await rpc(env, "fail_refund", { p_payment_id: paymentId }, f).catch(() => {});
    return { status: "failed" };
  }
}

// Mark the account ready (or not) and release any payouts that were waiting for it.
async function applyAccountState(env, f, accountId, enabled) {
  const providerId = await rpc(env, "set_payout_account_status", { p_account_id: accountId, p_enabled: enabled }, f);
  const sent = [];
  if (providerId && enabled) {
    const ids = await rpc(env, "payments_awaiting_payout", { p_account_id: accountId }, f);
    for (const id of ids ?? []) sent.push((await sendPayout(env, f, id)).status);
  }
  return sent;
}
const accountReady = (a) => a?.payouts_enabled === true && a?.details_submitted === true;

// POST {}                -> { url }  Stripe onboarding page for the signed-in provider
// POST { refresh: true } -> { enabled }  ask Stripe how setup went (and release waiting payouts)
export async function connectOnboard(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const user = token ? await getUser(token) : null;
  if (!user) return json({ error: "Please sign in" }, 401, c);
  const { refresh } = await req.json().catch(() => ({}));

  let row;
  try { [row] = await rpc(env, "payout_account_for_user", { p_user_id: user.id }, f); }
  catch (e) { return json({ error: e.message }, 400, c); }

  try {
    let accountId = row.stripe_account_id;
    if (refresh) {
      if (!accountId) return json({ enabled: false }, 200, c);
      const acct = await stripeApi(env, f, "GET", `accounts/${encodeURIComponent(accountId)}`);
      const enabled = accountReady(acct);
      await applyAccountState(env, f, accountId, enabled);
      return json({ enabled }, 200, c);
    }
    if (!accountId) {
      const form = { type: "express", country: "US", "capabilities[transfers][requested]": "true", "metadata[provider_id]": row.provider_id };
      if (row.email) form.email = row.email;
      const acct = await stripeApi(env, f, "POST", "accounts", form, `acct-${row.provider_id}`);
      accountId = acct.id;
      await rpc(env, "save_payout_account", { p_provider_id: row.provider_id, p_account_id: accountId }, f);
    }
    const link = await stripeApi(env, f, "POST", "account_links", {
      account: accountId,
      type: "account_onboarding",
      refresh_url: `${env.SITE_URL}/provider.html?tab=profile&connect=refresh`,
      return_url: `${env.SITE_URL}/provider.html?tab=profile&connect=return`,
    });
    return json({ url: link.url }, 200, c);
  } catch (e) {
    return json({ error: "Could not reach Stripe. Try again in a moment." }, 502, c);
  }
}

// POST { booking_id } from the provider: send my share now (used after "Mark completed", and as a retry)
export async function releasePayout(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const user = token ? await getUser(token) : null;
  if (!user) return json({ error: "Please sign in" }, 401, c);
  const { booking_id } = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/i.test(booking_id || "")) return json({ error: "Invalid booking" }, 400, c);

  try {
    const paymentId = await rpc(env, "find_payment", { p_booking_id: booking_id }, f);
    if (!paymentId) return json({ status: "not_paid" }, 200, c);
    return json(await sendPayout(env, f, paymentId, user.id), 200, c);
  } catch (e) {
    return json({ error: "Payment not found" }, 404, c);
  }
}

// POST { booking_id } from the customer or provider after a cancel (and as a retry): refund the customer now
export async function processRefund(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const user = token ? await getUser(token) : null;
  if (!user) return json({ error: "Please sign in" }, 401, c);
  const { booking_id } = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/i.test(booking_id || "")) return json({ error: "Invalid booking" }, 400, c);

  try {
    const paymentId = await rpc(env, "find_payment", { p_booking_id: booking_id }, f);
    if (!paymentId) return json({ status: "not_paid" }, 200, c);
    return json(await sendRefund(env, f, paymentId, user.id), 200, c);
  } catch (e) {
    return json({ error: "Payment not found" }, 404, c);
  }
}

// Provider asks to go Pro (POST {}) or to manage the plan (POST {manage:true}): -> { url }
export async function subscriptionCheckout(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const user = token ? await getUser(token) : null;
  if (!user) return json({ error: "Please sign in" }, 401, c);
  const { manage } = await req.json().catch(() => ({}));

  let row;
  try { [row] = await rpc(env, "subscription_context", { p_user_id: user.id }, f); }
  catch (e) { return json({ error: e.message }, 400, c); }

  try {
    let customer = row.stripe_customer_id;
    if (manage) {
      if (!customer) return json({ error: "You have no subscription to manage" }, 400, c);
      const ps = await stripeApi(env, f, "POST", "billing_portal/sessions", { customer, return_url: `${env.SITE_URL}/provider.html?tab=profile` });
      return json({ url: ps.url }, 200, c);
    }
    if (row.already_pro) return json({ error: "You are already on Wasel Pro" }, 400, c);
    // the admin can change the monthly price: the newest Stripe price lives in our settings; the env value is only the first/fallback one
    let priceId = null;
    try { priceId = await rpc(env, "platform_pro_price", {}, f); } catch { /* older database: fall back */ }
    priceId = priceId || env.STRIPE_PRO_PRICE_ID;
    if (!priceId) return json({ error: "Subscriptions are not set up yet" }, 503, c);
    if (!customer) {
      const form = { "metadata[provider_id]": row.provider_id, name: row.business_name };
      if (row.email) form.email = row.email;
      customer = (await stripeApi(env, f, "POST", "customers", form, `cust-${row.provider_id}`)).id;
      await rpc(env, "save_subscription_customer", { p_provider_id: row.provider_id, p_customer_id: customer }, f);
    }
    const session = await stripeApi(env, f, "POST", "checkout/sessions", {
      mode: "subscription",
      customer,
      "line_items[0][price]": priceId, // the price comes from our settings, never from the browser
      "line_items[0][quantity]": "1",
      success_url: `${env.SITE_URL}/provider.html?tab=profile&pro=1`,
      cancel_url: `${env.SITE_URL}/provider.html?tab=profile&pro=cancelled`,
      client_reference_id: row.provider_id,
      "subscription_data[metadata][provider_id]": row.provider_id,
    });
    return json({ url: session.url }, 200, c);
  } catch (e) {
    return json({ error: "Could not reach Stripe. Try again in a moment." }, 502, c);
  }
}

// Admin sets the monthly Wasel Pro price: POST { cents, reason }  (Authorization: the admin's Supabase JWT)
// Stripe prices cannot be edited, so this creates a NEW monthly price and saves it in our settings.
// New subscribers pay it; people who already subscribe keep the price they signed up at.
export async function setProPrice(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const user = token ? await getUser(token) : null;
  if (!user) return json({ error: "Please sign in" }, 401, c);
  try {
    if (!(await rpc(env, "check_admin", { p_user_id: user.id }, f))) return json({ error: "Not allowed" }, 403, c);
  } catch { return json({ error: "Not allowed" }, 403, c); }

  const { cents, reason } = await req.json().catch(() => ({}));
  const why = String(reason ?? "").trim();
  if (!Number.isInteger(cents) || cents < 100 || cents > 100000) return json({ error: "The monthly price must be between $1 and $1,000." }, 400, c);
  if (why.length < 5 || why.length > 500) return json({ error: "Please write a reason (at least 5 characters)." }, 400, c);

  try {
    const [cur] = await rpc(env, "public_settings", {}, f);
    if (cur && Number(cur.pro_price_cents) === cents) return json({ error: "That is already the current price." }, 400, c);
  } catch { /* the save below will still validate */ }

  let price;
  try {
    price = await stripeApi(env, f, "POST", "prices", {
      currency: "usd", unit_amount: String(cents), "recurring[interval]": "month",
      "product_data[name]": "Wasel Pro", "metadata[source]": "wasel-admin",
    }, `pro-price-${cents}-${user.id}-${Date.now() >> 17}`);
  } catch { return json({ error: "Could not reach Stripe. Try again in a moment." }, 502, c); }

  try {
    await rpc(env, "admin_save_pro_price", { p_admin_id: user.id, p_cents: cents, p_price_id: price.id, p_reason: why }, f);
  } catch (e) { return json({ error: e.message }, 400, c); }
  return json({ ok: true, cents, price_id: price.id }, 200, c);
}

// Stripe -> us. Always verify the signature before trusting anything.
// Two endpoints can point here (normal events and Connect events), each with its own signing secret.
export async function stripeWebhook(req, { env, fetch: f = fetch }) {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const raw = await req.text();
  const sig = req.headers.get("stripe-signature");
  let ok = false;
  for (const secret of [env.STRIPE_WEBHOOK_SECRET, env.STRIPE_CONNECT_WEBHOOK_SECRET]) {
    if (secret && (await verifyStripeSignature(raw, sig, secret))) { ok = true; break; }
  }
  if (!ok) return json({ error: "Bad signature" }, 400);

  const event = JSON.parse(raw);
  const s = event?.data?.object;

  try {
    if (event.type === "account.updated") {
      const sent = await applyAccountState(env, f, s.id, accountReady(s));
      return json({ received: true, payouts: sent });
    }

    if (event.type === "customer.subscription.created" || event.type === "customer.subscription.updated" || event.type === "customer.subscription.deleted") {
      const providerId = s.metadata?.provider_id;
      const customer = typeof s.customer === "string" ? s.customer : s.customer?.id;
      if (!/^[0-9a-f-]{36}$/i.test(providerId || "") || !customer) return json({ received: true, result: "ignored" });
      const item = s.items?.data?.[0];
      const secs = (n) => (n ? new Date(n * 1000).toISOString() : null);
      const result = await rpc(env, "apply_subscription_state", {
        p_provider_id: providerId, p_customer_id: customer, p_subscription_id: s.id,
        p_status: event.type === "customer.subscription.deleted" ? "canceled" : s.status,
        p_period_start: secs(s.current_period_start ?? item?.current_period_start),
        p_period_end: secs(s.current_period_end ?? item?.current_period_end),
      }, f);
      return json({ received: true, result });
    }

    if (event.type === "charge.dispute.created" || event.type === "charge.dispute.closed") {
      const pi = typeof s.payment_intent === "string" ? s.payment_intent : null;
      const closed = event.type === "charge.dispute.closed";
      const outcome = s.status === "won" || s.status === "warning_closed" ? "won" : s.status === "lost" ? "lost" : null;
      if (!pi || (closed && !outcome)) return json({ received: true, result: "ignored" });
      const result = await rpc(env, "record_dispute_event", {
        p_payment_intent: pi, p_dispute_id: s.id, p_kind: closed ? "closed" : "created", p_outcome: outcome,
      }, f);
      let payout;
      if (result === "won") { // the bank gave the money back to us: the provider can be paid now if the job is done
        const id = await rpc(env, "find_payment_by_intent", { p_payment_intent: pi }, f);
        if (id) payout = (await sendPayout(env, f, id)).status;
      }
      return json({ received: true, result, payout });
    }

    if (event.type === "charge.refunded") { // also covers refunds made by hand in the Stripe dashboard
      const pi = typeof s.payment_intent === "string" ? s.payment_intent : null;
      const refundId = s.refunds?.data?.[0]?.id ?? null;
      const result = pi && s.refunded ? await rpc(env, "record_refund_event", { p_payment_intent: pi, p_refund_id: refundId }, f) : "ignored";
      return json({ received: true, result });
    }

    if (s?.mode === "subscription") return json({ received: true, ignored: true }); // plans are handled by the subscription events

    const map = {
      "checkout.session.completed": s?.payment_status === "paid" ? "paid" : "ignore",
      "checkout.session.async_payment_succeeded": "paid",
      "checkout.session.async_payment_failed": "failed",
      "checkout.session.expired": "expired",
    };
    const outcome = map[event?.type] ?? "ignore";
    if (outcome === "ignore") return json({ received: true, ignored: true });

    const result = await rpc(env, "record_payment_result", {
      p_session_id: s.id,
      p_payment_intent: typeof s.payment_intent === "string" ? s.payment_intent : null,
      p_amount_paid: s.amount_total != null ? s.amount_total / 100 : null,
      p_outcome: outcome,
    }, f);

    let payout;
    if (result === "paid") { // the service may already be completed: then the provider is paid now
      const id = await rpc(env, "find_payment_by_session", { p_session_id: s.id }, f);
      payout = (await sendPayout(env, f, id)).status;
    }
    let refund;
    if (result === "paid_cancelled") { // customer paid after the booking was cancelled: give it back
      const id = await rpc(env, "find_payment_by_session", { p_session_id: s.id }, f);
      refund = (await sendRefund(env, f, id)).status;
    }
    return json({ received: true, result, payout, refund });
  } catch (e) {
    return json({ error: "Could not record event" }, 500); // Stripe will retry
  }
}


// Scheduler (every few minutes): pay out jobs the customer never answered after 72 hours (and retry failed payouts).
// Allowed only with the shared secret header, never with a user token.
export async function releaseDuePayouts(req, { env, fetch: f = fetch }) {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const secret = env.CRON_SECRET || env.EMAIL_CRON_SECRET || "";
  const given = req.headers.get("x-cron-secret") || "";
  let d = secret.length === 0 || given.length !== secret.length ? 1 : 0;
  for (let i = 0; i < given.length && i < secret.length; i++) d |= given.charCodeAt(i) ^ secret.charCodeAt(i);
  if (d !== 0) return json({ error: "Not allowed" }, 401);
  let ids;
  try { ids = (await rpc(env, "payments_due_for_release", {}, f)) || []; } catch { return json({ error: "Could not read the list" }, 500); }
  let sent = 0, other = 0;
  for (const id of ids) {
    try { (await sendPayout(env, f, id)).status === "sent" ? sent++ : other++; } catch { other++; }
  }
  return json({ checked: ids.length, sent, other });
}
