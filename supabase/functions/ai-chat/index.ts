// Customer help chat. The browser sends the conversation here; this function adds what Wasel offers
// and forwards it to OmniRoute (an OpenAI-compatible AI gateway), so the OmniRoute key never reaches the browser.
//
// Secrets (Supabase dashboard -> Edge Functions -> Secrets, or `supabase secrets set ...`):
//   OMNIROUTE_URL      e.g. https://ai.example.com   (where OmniRoute runs; must be reachable from the internet)
//   OMNIROUTE_API_KEY  an API key created in the OmniRoute dashboard
//   OMNIROUTE_MODEL    optional, the model or combo name to use (default "auto")
// Deploy: supabase functions deploy ai-chat --no-verify-jwt   (visitors who are not logged in can use it too)

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

const MAX_MESSAGES = 12;     // only the latest part of the conversation is sent
const MAX_CHARS = 1000;      // per message

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });

type Msg = { role: "user" | "assistant"; content: string };

function cleanMessages(input: unknown): Msg[] | null {
  if (!Array.isArray(input)) return null;
  const out: Msg[] = [];
  for (const m of input.slice(-MAX_MESSAGES)) {
    if (!m || (m.role !== "user" && m.role !== "assistant") || typeof m.content !== "string") return null;
    const content = m.content.trim().slice(0, MAX_CHARS);
    if (content) out.push({ role: m.role, content });
  }
  return out.length && out[out.length - 1].role === "user" ? out : null;
}

// A short list of real services so answers match what is on the site. Read with the public key, so RLS applies.
async function serviceList(): Promise<string> {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !key) return "";
  try {
    const res = await fetch(
      `${url}/rest/v1/services?select=name,category,price,provider:provider_profiles!inner(business_name,city)&order=created_at.desc&limit=40`,
      { headers: { apikey: key, authorization: `Bearer ${key}` } },
    );
    if (!res.ok) return "";
    const rows = await res.json();
    return rows
      .map((r: any) => `- ${r.name} (${r.category}, $${Number(r.price).toFixed(2)}) by ${r.provider?.business_name ?? "?"}, ${r.provider?.city ?? ""}`)
      .join("\n");
  } catch {
    return "";
  }
}

function systemPrompt(services: string, lang: string) {
  return [
    "You are the help assistant of Wasel, a website in Texas where customers book trusted local service providers.",
    "Categories: Car Detailing, Home Cleaning, Handyman, Computer Repair.",
    "How it works: search services by city or ZIP on the Services page, open a service, pick a time and book. " +
      "Customers see and manage their bookings on the My bookings page. Providers sign up with \"Become a provider\".",
    "Help people find the right service and use the site. Keep answers short and friendly.",
    "Only talk about Wasel and its services. Never invent services, prices, providers or policies; if you do not know, " +
      "say so and suggest the Services page or the Contact page.",
    "You cannot see or change bookings, accounts or payments.",
    `Reply in the language the customer writes in (the site is currently shown in ${lang === "es" ? "Spanish" : "English"}).`,
    services ? `Some services currently listed:\n${services}` : "",
  ].filter(Boolean).join("\n");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const base = Deno.env.get("OMNIROUTE_URL")?.replace(/\/+$/, "");
  const apiKey = Deno.env.get("OMNIROUTE_API_KEY");
  if (!base || !apiKey) return json({ error: "The assistant is not set up yet." }, 503);

  const body = await req.json().catch(() => null);
  const messages = cleanMessages(body?.messages);
  if (!messages) return json({ error: "Please type a question." }, 400);
  const lang = body?.lang === "es" ? "es" : "en";

  let res: Response;
  try {
    res = await fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model: Deno.env.get("OMNIROUTE_MODEL") || "auto",
        messages: [{ role: "system", content: systemPrompt(await serviceList(), lang) }, ...messages],
        max_tokens: 500,
        temperature: 0.4,
        stream: false,
      }),
      signal: AbortSignal.timeout(45_000),
    });
  } catch (e) {
    console.error("OmniRoute unreachable:", e);
    return json({ error: "The assistant is not available right now. Try again later." }, 502);
  }

  const out = await res.json().catch(() => null);
  const reply = out?.choices?.[0]?.message?.content;
  if (!res.ok || typeof reply !== "string" || !reply.trim()) {
    console.error("OmniRoute error:", res.status, JSON.stringify(out)?.slice(0, 500));
    return json({ error: "The assistant could not answer right now. Try again later." }, 502);
  }
  return json({ reply: reply.trim() });
});
