// Booking emails. Node-testable; the Edge Function is a thin wrapper (send-emails/index.ts).
import { json } from "./logic.js";

const cors = (origin) => ({
  "access-control-allow-origin": origin || "*",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info, x-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS",
});

export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const line = (s) => String(s ?? "").replace(/[\r\n]+/g, " ").trim();
const usd = (n) => "$" + Number(n || 0).toFixed(2);

const LOCALE = { en: "en-US", es: "es-US" };
const when = (iso, lang) => new Date(iso).toLocaleString(LOCALE[lang] || "en-US", { timeZone: "America/Chicago", dateStyle: "medium", timeStyle: "short" }) + " CT";

// Words that are not part of a single sentence, per language.
const WORDS = {
  en: {
    who: { admin: "admin", provider: "provider", customer: "customer" },
    hi: (n) => (n ? `Hi ${n},` : "Hello,"),
    footer: (who) => `You receive this because you have a Wasel ${who} account.`,
    openDash: "Open your dashboard", viewBooking: "View my booking",
    topics: { general: "General question", booking: "A booking", payment: "A payment or refund", provider: "Becoming or being a provider", account: "My account", privacy: "Privacy or deleting my data", other: "Something else" },
  },
  es: {
    who: { admin: "de administrador", provider: "de proveedor", customer: "de cliente" },
    hi: (n) => (n ? `Hola ${n},` : "Hola,"),
    footer: (who) => `Recibes este correo porque tienes una cuenta ${who} en Wasel.`,
    openDash: "Abrir tu panel", viewBooking: "Ver mi reserva",
    topics: { general: "Pregunta general", booking: "Una reserva", payment: "Un pago o reembolso", provider: "Ser proveedor o ya serlo", account: "Mi cuenta", privacy: "Privacidad o borrar mis datos", other: "Otra cosa" },
  },
};

// One entry per kind: (row, f) -> { subject, intro, cta, link? }. f = { svc, date, city, usd, auto }
const KINDS = {
  en: {
    booking_new: (r, f) => ({ subject: `New booking request: ${f.svc}`, cta: "Review the request",
      intro: `${r.customer_name || "A customer"} requested ${f.svc} on ${f.date}${f.city ? ` in ${f.city}` : ""}. Please confirm or decline it in your dashboard.` }),
    booking_confirmed: (r, f) => ({ subject: `Booking confirmed: ${f.svc}`, cta: "Pay now",
      intro: `${r.business_name} confirmed your booking for ${f.svc} on ${f.date}. You can now pay securely by card from My bookings.` }),
    booking_declined: (r, f) => ({ subject: `Booking declined: ${f.svc}`, cta: "Find another provider",
      intro: `${r.business_name} could not take your booking for ${f.svc} on ${f.date}. If you already paid, you will be refunded in full automatically.` }),
    booking_cancelled: (r, f) => ({ subject: `Booking cancelled: ${f.svc}`,
      intro: r.to_is_provider
        ? `${r.customer_name || "The customer"} cancelled the booking for ${f.svc} on ${f.date}.`
        : `Your booking for ${f.svc} on ${f.date} with ${r.business_name} was cancelled. If you already paid, you will be refunded in full.` }),
    refund_done: (r, f) => ({ subject: `Your refund of ${f.usd(r.refund_amount)} is on its way`,
      intro: `We refunded ${f.usd(r.refund_amount)} for your cancelled booking of ${f.svc}. Banks usually take 5–10 business days to show it on your statement.` }),
    booking_completed: (r, f) => ({ subject: `Is the job done? ${f.svc}`, cta: "Confirm or rate",
      intro: `${r.business_name} marked ${f.svc} as completed. Please confirm that the job is done, or report a problem. If you do nothing, it is confirmed automatically after 72 hours and ${r.business_name} is paid. You can also leave a star rating and a comment.` }),
    booking_starting_soon: (r, f) => ({ subject: `Starting in about an hour: ${f.svc}`, cta: "View my booking",
      intro: `${r.business_name} is scheduled to start ${f.svc} at ${f.date}. The work starts within the hour. You can message your provider from My bookings, and you can no longer cancel online.` }),
    completion_reminder: (r, f) => ({ subject: `Reminder: please confirm ${f.svc}`, cta: "Confirm or report a problem",
      intro: `${r.business_name} finished ${f.svc}. If you do nothing, it will be confirmed automatically on ${f.auto || "in about 24 hours"} and ${r.business_name} will be paid. Was everything done properly? Confirm it, or report a problem before then.` }),
    completion_confirmed: (r, f) => ({ subject: `Customer confirmed: ${f.svc}`,
      intro: `${r.customer_name || "The customer"} confirmed that ${f.svc} is done. Your payout can now be sent.` }),
    problem_reported: (r, f) => ({ subject: `Problem reported: ${f.svc}`,
      intro: `${r.customer_name || "The customer"} reported a problem with ${f.svc} on ${f.date}. Your payout is on hold until Wasel support reviews it.` }),
    service_pending: (r, f) => ({ subject: `New service waiting for approval: ${f.svc}`, cta: "Review the service", link: "/admin.html?tab=approvals",
      intro: `${r.business_name} added or changed “${f.svc}” (${f.usd(r.price)}). Customers cannot see it until you approve it.` }),
    service_approved: (r, f) => ({ subject: `Your service was approved: ${f.svc}`, cta: "See your services", link: "/provider.html?tab=services",
      intro: `“${f.svc}” was approved. Customers can now find it and book it${r.approval_note ? `. Note from Wasel: ${r.approval_note}` : "."}` }),
    service_rejected: (r, f) => ({ subject: `Your service was not approved: ${f.svc}`, cta: "Fix the service", link: "/provider.html?tab=services",
      intro: `“${f.svc}” was not approved. Reason: ${r.approval_note || "no reason given"}. Fix the service, then send it for review again from your Services page.` }),
    service_needs_info: (r, f) => ({ subject: `More information needed: ${f.svc}`, cta: "Update the service", link: "/provider.html?tab=services",
      intro: `Wasel needs more information about “${f.svc}”: ${r.approval_note || "please check the service and its documents"}. Update the service or its documents, then send it for review again from your Services page.` }),
    provider_new: (r, f) => ({ subject: `New provider application: ${r.business_name}`, cta: "Review the application", link: "/admin.html?tab=providers",
      intro: `${r.business_name} applied to become a provider (or sent its application again). Review the details and documents, then approve, reject or ask for more information.` }),
    provider_approved: (r, f) => ({ subject: "Your Wasel application was approved", cta: "Open your dashboard", link: "/provider.html",
      intro: `Welcome to Wasel! ${r.business_name} was approved. Customers can now find you${r.approval_note ? `. Note from Wasel: ${r.approval_note}` : "."} Add your services to start getting bookings.` }),
    provider_rejected: (r, f) => ({ subject: "Your Wasel application was not approved", cta: "Open your dashboard", link: "/provider.html",
      intro: `We could not approve ${r.business_name}. Reason: ${r.approval_note || "no reason given"}. If you think this is a mistake, please contact us.` }),
    provider_needs_info: (r, f) => ({ subject: "Wasel needs more information about your application", cta: "Update your application", link: "/provider.html?tab=profile",
      intro: `To review ${r.business_name}, Wasel needs more information: ${r.approval_note || "please check your profile and documents"}. Update your profile or documents, then send your application again from your dashboard.` }),
    rating_alert: (r, f) => ({ subject: `Rating alert: ${r.business_name}`, cta: "Review the alert", link: "/admin.html?tab=alerts",
      intro: `${r.business_name} now has an average rating of ${Number(r.alert_avg).toFixed(1)} from ${r.alert_count} reviews, below your alert limit. Please look at the reviews and decide whether to do nothing or suspend the provider.` }),
    contact_new: (r, f) => ({ subject: `New contact message: ${f.topic}`, cta: "Open Messages", link: "/admin.html?tab=messages",
      intro: `${line(r.contact_name)} (${line(r.contact_email)}) wrote: ${f.msg}` }),
  },
  es: {
    booking_new: (r, f) => ({ subject: `Nueva solicitud de reserva: ${f.svc}`, cta: "Revisar la solicitud",
      intro: `${r.customer_name || "Un cliente"} solicitó ${f.svc} para el ${f.date}${f.city ? ` en ${f.city}` : ""}. Confírmala o recházala en tu panel.` }),
    booking_confirmed: (r, f) => ({ subject: `Reserva confirmada: ${f.svc}`, cta: "Pagar ahora",
      intro: `${r.business_name} confirmó tu reserva de ${f.svc} para el ${f.date}. Ya puedes pagar de forma segura con tarjeta desde Mis reservas.` }),
    booking_declined: (r, f) => ({ subject: `Reserva rechazada: ${f.svc}`, cta: "Buscar otro proveedor",
      intro: `${r.business_name} no pudo aceptar tu reserva de ${f.svc} para el ${f.date}. Si ya pagaste, se te reembolsará el monto completo automáticamente.` }),
    booking_cancelled: (r, f) => ({ subject: `Reserva cancelada: ${f.svc}`,
      intro: r.to_is_provider
        ? `${r.customer_name || "El cliente"} canceló la reserva de ${f.svc} para el ${f.date}.`
        : `Tu reserva de ${f.svc} para el ${f.date} con ${r.business_name} fue cancelada. Si ya pagaste, se te reembolsará el monto completo.` }),
    refund_done: (r, f) => ({ subject: `Tu reembolso de ${f.usd(r.refund_amount)} va en camino`,
      intro: `Reembolsamos ${f.usd(r.refund_amount)} por tu reserva cancelada de ${f.svc}. Los bancos suelen tardar de 5 a 10 días hábiles en mostrarlo en tu estado de cuenta.` }),
    booking_completed: (r, f) => ({ subject: `¿Está terminado el trabajo? ${f.svc}`, cta: "Confirmar o calificar",
      intro: `${r.business_name} marcó ${f.svc} como completado. Confirma que el trabajo está terminado, o reporta un problema. Si no haces nada, se confirma automáticamente después de 72 horas y se le paga a ${r.business_name}. También puedes dejar estrellas y un comentario.` }),
    booking_starting_soon: (r, f) => ({ subject: `Empieza en aproximadamente una hora: ${f.svc}`, cta: "Ver mi reserva",
      intro: `${r.business_name} tiene programado empezar ${f.svc} a las ${f.date}. El trabajo empieza en menos de una hora. Puedes escribirle a tu proveedor desde Mis reservas, y ya no se puede cancelar en línea.` }),
    completion_reminder: (r, f) => ({ subject: `Recordatorio: confirma ${f.svc}`, cta: "Confirmar o reportar un problema",
      intro: `${r.business_name} terminó ${f.svc}. Si no haces nada, se confirmará automáticamente el ${f.auto || "en unas 24 horas"} y se le pagará a ${r.business_name}. ¿Se hizo todo bien? Confírmalo, o reporta un problema antes de esa fecha.` }),
    completion_confirmed: (r, f) => ({ subject: `El cliente confirmó: ${f.svc}`,
      intro: `${r.customer_name || "El cliente"} confirmó que ${f.svc} está terminado. Ya se puede enviar tu pago.` }),
    problem_reported: (r, f) => ({ subject: `Problema reportado: ${f.svc}`,
      intro: `${r.customer_name || "El cliente"} reportó un problema con ${f.svc} del ${f.date}. Tu pago está en espera hasta que el equipo de Wasel lo revise.` }),
    service_pending: (r, f) => ({ subject: `Servicio nuevo esperando aprobación: ${f.svc}`, cta: "Revisar el servicio", link: "/admin.html?tab=approvals",
      intro: `${r.business_name} agregó o cambió “${f.svc}” (${f.usd(r.price)}). Los clientes no pueden verlo hasta que lo apruebes.` }),
    service_approved: (r, f) => ({ subject: `Tu servicio fue aprobado: ${f.svc}`, cta: "Ver tus servicios", link: "/provider.html?tab=services",
      intro: `“${f.svc}” fue aprobado. Los clientes ya pueden encontrarlo y reservarlo${r.approval_note ? `. Nota de Wasel: ${r.approval_note}` : "."}` }),
    service_rejected: (r, f) => ({ subject: `Tu servicio no fue aprobado: ${f.svc}`, cta: "Corregir el servicio", link: "/provider.html?tab=services",
      intro: `“${f.svc}” no fue aprobado. Motivo: ${r.approval_note || "no se indicó motivo"}. Corrige el servicio y envíalo de nuevo a revisión desde tu página de Servicios.` }),
    service_needs_info: (r, f) => ({ subject: `Se necesita más información: ${f.svc}`, cta: "Actualizar el servicio", link: "/provider.html?tab=services",
      intro: `Wasel necesita más información sobre “${f.svc}”: ${r.approval_note || "revisa el servicio y sus documentos"}. Actualiza el servicio o sus documentos y envíalo de nuevo a revisión desde tu página de Servicios.` }),
    provider_new: (r, f) => ({ subject: `Nueva solicitud de proveedor: ${r.business_name}`, cta: "Revisar la solicitud", link: "/admin.html?tab=providers",
      intro: `${r.business_name} solicitó ser proveedor (o envió su solicitud de nuevo). Revisa los datos y los documentos, y luego aprueba, rechaza o pide más información.` }),
    provider_approved: (r, f) => ({ subject: "Tu solicitud en Wasel fue aprobada", cta: "Abrir tu panel", link: "/provider.html",
      intro: `¡Bienvenido a Wasel! ${r.business_name} fue aprobado. Los clientes ya pueden encontrarte${r.approval_note ? `. Nota de Wasel: ${r.approval_note}` : "."} Agrega tus servicios para empezar a recibir reservas.` }),
    provider_rejected: (r, f) => ({ subject: "Tu solicitud en Wasel no fue aprobada", cta: "Abrir tu panel", link: "/provider.html",
      intro: `No pudimos aprobar a ${r.business_name}. Motivo: ${r.approval_note || "no se indicó motivo"}. Si crees que es un error, contáctanos.` }),
    provider_needs_info: (r, f) => ({ subject: "Wasel necesita más información sobre tu solicitud", cta: "Actualizar tu solicitud", link: "/provider.html?tab=profile",
      intro: `Para revisar a ${r.business_name}, Wasel necesita más información: ${r.approval_note || "revisa tu perfil y tus documentos"}. Actualiza tu perfil o tus documentos y envía la solicitud de nuevo desde tu panel.` }),
    rating_alert: (r, f) => ({ subject: `Alerta de calificación: ${r.business_name}`, cta: "Revisar la alerta", link: "/admin.html?tab=alerts",
      intro: `${r.business_name} tiene ahora una calificación promedio de ${Number(r.alert_avg).toFixed(1)} con ${r.alert_count} reseñas, por debajo de tu límite de alerta. Revisa las reseñas y decide si no hacer nada o suspender al proveedor.` }),
    contact_new: (r, f) => ({ subject: `Nuevo mensaje de contacto: ${f.topic}`, cta: "Abrir Mensajes", link: "/admin.html?tab=messages",
      intro: `${line(r.contact_name)} (${line(r.contact_email)}) escribió: ${f.msg}` }),
  },
};

// row = one line from claim_emails()  ->  { subject, text, html }.  row.to_lang ('en' | 'es') picks the language.
export function renderEmail(row, siteUrl) {
  const lang = row.to_lang === "es" ? "es" : "en";
  const W = WORDS[lang];
  const base = String(siteUrl || "").replace(/\/+$/, "");
  const adminKind = ["service_pending", "contact_new", "provider_new", "rating_alert"].includes(row.kind);
  const providerKind = ["service_approved", "service_rejected", "service_needs_info", "provider_approved", "provider_rejected", "provider_needs_info"].includes(row.kind);
  const who = adminKind ? "admin" : (row.to_is_provider || providerKind) ? "provider" : "customer";
  const make = KINDS[lang][row.kind];
  if (!make) throw new Error("Unknown email kind");
  const f = {
    svc: row.service_name, date: when(row.scheduled_at, lang), city: row.city, usd,
    auto: row.completed_at ? when(new Date(new Date(row.completed_at).getTime() + 72 * 3600 * 1000).toISOString(), lang) : "",
    topic: W.topics[row.contact_topic] || (lang === "es" ? "Mensaje" : "Message"),
    msg: String(row.contact_message || "").replace(/\s+/g, " ").trim().slice(0, 600),
  };
  const m = make(row, f);
  const link = base + (m.link || (adminKind ? "/admin.html" : who === "provider" ? "/provider.html" : "/bookings.html"));
  const cta = m.cta || (row.to_is_provider ? W.openDash : W.viewBooking);
  const greeting = W.hi(row.to_name ? line(row.to_name) : "");
  const footer = W.footer(W.who[who]);
  const text = `${greeting}\n\n${m.intro}\n\n${cta}: ${link}\n\n— Wasel\n${footer}`;
  const html = `<div lang="${lang}" style="font-family:system-ui,Segoe UI,Arial,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#0f172a">
<p style="font-size:18px;font-weight:700;margin:0 0 16px">Wasel</p><p>${esc(greeting)}</p><p>${esc(m.intro)}</p>
<p style="margin:24px 0"><a href="${esc(link)}" style="background:#1f6360;color:#fff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:600;display:inline-block">${esc(cta)}</a></p>
<p style="color:#64748b;font-size:12px">${esc(footer)}</p></div>`;
  return { subject: line(m.subject).slice(0, 200), text, html };
}

async function rpc(env, fn, args, f) {
  const r = await f(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: env.SERVICE_KEY, authorization: `Bearer ${env.SERVICE_KEY}`, "content-type": "application/json" },
    body: JSON.stringify(args),
  });
  const body = await r.json().catch(() => null);
  if (!r.ok) throw new Error(body?.message || "Database error");
  return body;
}

function sameSecret(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Sends one email through Resend. Returns {ok} | {ok:false, permanent, error}
export async function deliver(env, f, row) {
  const mail = renderEmail(row, env.SITE_URL);
  let r;
  try {
    r = await f("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json", "idempotency-key": `wasel-email-${row.id}` },
      body: JSON.stringify({ from: env.EMAIL_FROM, to: [row.to_email], subject: mail.subject, html: mail.html, text: mail.text,
        // answering a contact notification goes to the person who wrote, not to us
        ...(row.kind === "contact_new" && row.contact_email ? { reply_to: line(row.contact_email) } : {}) }),
    });
  } catch (e) { return { ok: false, permanent: false, error: "network: " + (e?.message || e) }; }
  if (r.ok) return { ok: true };
  const body = await r.json().catch(() => ({}));
  return { ok: false, permanent: r.status >= 400 && r.status < 500 && r.status !== 429 && r.status !== 408, error: `resend ${r.status}: ${body?.message || ""}` };
}

// POST (no body needed). Allowed: the scheduler (x-cron-secret) or any signed-in user (it only works through the
// queue the database wrote, so a user cannot choose who gets what).
export async function sendEmails(req, { env, getUser, fetch: f = fetch }) {
  const c = cors(env.SITE_URL);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, c);
  const cron = req.headers.get("x-cron-secret") || "";
  let allowed = !!env.EMAIL_CRON_SECRET && sameSecret(cron, env.EMAIL_CRON_SECRET);
  if (!allowed) {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    allowed = !!(token && await getUser(token));
  }
  if (!allowed) return json({ error: "Not allowed" }, 401, c);
  if (!env.RESEND_API_KEY || !env.EMAIL_FROM) return json({ error: "Email is not set up", sent: 0 }, 503, c); // queue just waits

  let rows;
  try { rows = await rpc(env, "claim_emails", { p_limit: 20 }, f); } catch { return json({ error: "Could not read the queue" }, 500, c); }
  let sent = 0, failed = 0;
  for (const row of rows || []) {
    let res;
    try { res = await deliver(env, f, row); } catch (e) { res = { ok: false, permanent: true, error: "render: " + (e?.message || e) }; }
    try { await rpc(env, "finish_email", { p_id: row.id, p_ok: res.ok, p_error: res.error ?? null, p_permanent: !!res.permanent }, f); } catch { /* stale 'sending' rows are re-claimed after 10 min */ }
    res.ok ? sent++ : failed++;
  }
  return json({ sent, failed }, 200, c);
}
