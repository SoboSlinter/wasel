import { openDoc, KIND_LABEL } from "./docs.js";
import { icon, adoptTabs, sb, renderChrome, esc, money, formatDateTime, params, showMessage, friendlyMessage, callFunction, kickEmails, pct, dollars, getSettings, CATEGORIES } from "./app.js";

const root = document.getElementById("admin");
const user = await renderChrome();
let IS_SUPER = false; // the main admin: manages admins, edits user and provider data

const pill = (cls, label) => `<span class="badge ${esc(cls)}">${esc(label)}</span>`;
const PROVIDER_LABEL = { pending: "Waiting for approval", approved: "Approved", suspended: "Suspended" };
const BOOKING_LABEL = { pending: "Pending", confirmed: "Confirmed", in_progress: "In progress", completed: "Completed", cancelled: "Cancelled", declined: "Declined" };
const CATEGORY_LABEL = { car_detailing: "Car Detailing", home_cleaning: "Home Cleaning", handyman: "Handyman", computer_repair: "Computer Repair" };
const REFERRAL_LABEL = { friend: "Friend or family", social: "Social media", search: "Online search", flyer: "Flyer or in person", other: "Other" };
const dateOnly = (iso) => new Date(iso).toLocaleDateString(window.waselLocale, { timeZone: "America/Chicago", month: "short", day: "numeric", year: "numeric" });

// Asks the admin WHY before a risky action. Resolves to the reason text, or null if they cancel.
// The reason is saved in the audit log, so it is required.
function askReason({ title, text, confirm = "Confirm", danger = false }) {
  return new Promise((resolve) => {
    const dlg = document.createElement("dialog");
    dlg.className = "reason-dialog";
    dlg.innerHTML = `<form method="dialog" class="reason-form" novalidate>
      <h2 style="font-size:1.125rem;margin:0 0 6px">${esc(title)}</h2>
      <p class="small muted" style="margin:0 0 12px">${esc(text)}</p>
      <label for="reason-text">Reason <span class="muted small">(saved in the activity log)</span></label>
      <textarea id="reason-text" rows="3" maxlength="500" required minlength="5"></textarea>
      <div id="reason-err" class="alert alert-error" hidden></div>
      <div class="btn-row" style="margin-top:12px;justify-content:flex-end">
        <button type="button" class="btn btn-sm btn-outline" data-cancel>Cancel</button>
        <button type="submit" class="btn btn-sm ${danger ? "btn-danger" : ""}" data-ok>${esc(confirm)}</button>
      </div></form>`;
    document.body.appendChild(dlg);
    const done = (v) => { dlg.close(); dlg.remove(); resolve(v); };
    dlg.querySelector("[data-cancel]").onclick = () => done(null);
    dlg.addEventListener("cancel", (e) => { e.preventDefault(); done(null); });
    dlg.querySelector("form").onsubmit = (e) => {
      e.preventDefault();
      const v = dlg.querySelector("#reason-text").value.trim();
      if (v.length < 5) return showMessage(dlg.querySelector("#reason-err"), "Please write a reason (at least 5 characters).");
      done(v);
    };
    dlg.showModal();
    dlg.querySelector("#reason-text").focus();
  });
}

// A small edit form with a required reason. Resolves to { values, reason } or null if cancelled.
function askForm({ title, text, fields, confirm = "Save" }) {
  return new Promise((resolve) => {
    const dlg = document.createElement("dialog");
    dlg.className = "reason-dialog";
    dlg.innerHTML = `<form method="dialog" class="reason-form" novalidate>
      <h2 style="font-size:1.125rem;margin:0 0 6px">${esc(title)}</h2>
      <p class="small muted" style="margin:0 0 12px">${esc(text)}</p>
      ${fields.map((f, i) => `<div class="field" style="margin-bottom:10px"><label for="af-${i}">${esc(f.label)}</label>${f.rows
        ? `<textarea id="af-${i}" rows="${f.rows}" maxlength="${f.max ?? 500}">${esc(f.value ?? "")}</textarea>`
        : `<input id="af-${i}" type="${f.type ?? "text"}" maxlength="${f.max ?? 200}" value="${esc(f.value ?? "")}">`}</div>`).join("")}
      <div class="field" style="margin-bottom:10px"><label for="af-reason">Reason <span class="muted small">(saved in the activity log)</span></label><textarea id="af-reason" rows="2" maxlength="500" required minlength="5"></textarea></div>
      <div id="af-err" class="alert alert-error" hidden></div>
      <div class="btn-row" style="margin-top:12px;justify-content:flex-end">
        <button type="button" class="btn btn-sm btn-outline" data-cancel>Cancel</button>
        <button type="submit" class="btn btn-sm">${esc(confirm)}</button>
      </div></form>`;
    document.body.appendChild(dlg);
    const done = (v) => { dlg.close(); dlg.remove(); resolve(v); };
    dlg.querySelector("[data-cancel]").onclick = () => done(null);
    dlg.addEventListener("cancel", (e) => { e.preventDefault(); done(null); });
    dlg.querySelector("form").onsubmit = (e) => {
      e.preventDefault();
      const values = fields.map((f, i) => dlg.querySelector(`#af-${i}`).value.trim());
      for (const [i, f] of fields.entries()) if (f.required && !values[i]) return showMessage(dlg.querySelector("#af-err"), `${f.label} is required.`);
      const reason = dlg.querySelector("#af-reason").value.trim();
      if (reason.length < 5) return showMessage(dlg.querySelector("#af-err"), "Please write a reason (at least 5 characters).");
      done({ values, reason });
    };
    dlg.showModal();
    dlg.querySelector("#af-0").focus();
  });
}

async function init(user) {
  // The page checks the role to decide what to show. The REAL protection is in the database:
  // a non-admin cannot read other people's data or call the admin functions, whatever they do here.
  const { data: me } = await sb.from("profiles").select("role, is_super_admin").eq("id", user.id).maybeSingle();
  if (me?.role !== "admin") {
    root.innerHTML = `<div class="empty"><h1 style="font-size:1.5rem">Admins only</h1>
      <p>You don't have access to this page.</p><a class="link" href="admin-login.html">Admin log in</a></div>`;
    return;
  }

  IS_SUPER = me?.is_super_admin === true;
  const tabParam = params().get("tab") === "approvals" ? "catalog" : params().get("tab");
  const tab = ["overview", "providers", "catalog", "users", "bookings", "disputes", "problems", "messages", "alerts", "content", "activity", "settings", ...(IS_SUPER ? ["admins"] : [])].includes(tabParam) ? tabParam : "overview";
  const tabs = [["overview", "Overview", "dashboard"], ["providers", "Providers", "briefcase"], ["catalog", "Services", "shield"], ["users", "Users", "users"], ...(IS_SUPER ? [["admins", "Admins", "shield"]] : []), ["bookings", "Bookings", "calendar"], ["disputes", "Disputes", "alert"], ["problems", "Problems", "wrench"], ["messages", "Messages", "mail"], ["alerts", "Alerts", "alert"], ["content", "Content", "layers"], ["activity", "Activity", "activity"], ["settings", "Settings", "settings"]];
  const [{ count: waiting }, { count: openDisputes }, { count: openProblems }, { count: newMessages }, { count: openAlerts }] = await Promise.all([
    sb.from("provider_profiles").select("id", { count: "exact", head: true }).eq("status", "pending"),
    sb.from("payments").select("id", { count: "exact", head: true }).eq("dispute_status", "open"),
    sb.from("bookings").select("id", { count: "exact", head: true }).eq("problem_status", "open"),
    sb.rpc("admin_contact_messages", { p_status: "new" }).then((r) => ({ count: r.data?.length ?? 0 })),
    sb.rpc("admin_alerts_list").then((r) => ({ count: (r.data ?? []).filter((a) => a.status === "open").length })),
  ]);
  const badge = { providers: waiting, disputes: openDisputes, problems: openProblems, messages: newMessages, alerts: openAlerts };
  root.innerHTML = `
    <h1 style="font-size:1.875rem">Admin</h1>
    <p class="muted" style="margin:4px 0 0">Review providers, manage people and keep an eye on bookings and payments.${IS_SUPER ? ' <span class="badge admin">Main admin</span>' : ""}</p>
    <div class="dash">
      <nav class="tabs" aria-label="Admin sections">${tabs.map(([k, l, i]) => `<a class="tab ${k === tab ? "active" : ""}" href="admin.html?tab=${k}" data-tab="${k}">${icon(i)}<span>${l}</span>${badge[k] ? ` <span class="count">${badge[k]}</span>` : ""}</a>`).join("")}</nav>
      <div id="tab-body"><p class="muted loading" style="margin-top:24px">Loading…</p></div>
    </div>`;
  adoptTabs();
  const body = document.getElementById("tab-body");
  if (tab === "overview") await tabOverview(body);
  if (tab === "providers") await tabProviders(body);
  if (tab === "catalog") await tabCatalog(body);
  if (tab === "users") await tabUsers(body, user);
  if (tab === "admins") await tabAdmins(body, user);
  if (tab === "bookings") await tabBookings(body);
  if (tab === "disputes") await tabDisputes(body);
  if (tab === "problems") await tabProblems(body);
  if (tab === "messages") await tabMessages(body);
  if (tab === "alerts") await tabAlerts(body);
  if (tab === "content") await tabContent(body);
  if (tab === "activity") await tabActivity(body);
  if (tab === "settings") await tabSettings(body);
}

// ---------------------------------------------------------------- overview
async function tabOverview(body) {
  const count = async (table, filter) => {
    let q = sb.from(table).select("*", { count: "exact", head: true });
    if (filter) q = filter(q);
    const { count: n } = await q;
    return n ?? 0;
  };
  const [users, providers, pendingProviders, services, bookings, pendingBookings] = await Promise.all([
    count("profiles"), count("provider_profiles"), count("provider_profiles", (q) => q.eq("status", "pending")),
    count("services"), count("bookings"), count("bookings", (q) => q.eq("status", "pending")),
  ]);
  const settings = await getSettings();
  const { data: done } = await sb.from("bookings").select("service_price, platform_commission").eq("status", "completed");
  const gross = (done ?? []).reduce((a, b) => a + Number(b.service_price), 0);
  const fees = (done ?? []).reduce((a, b) => a + Number(b.platform_commission), 0);

  // payments + status mix + latest bookings (all admin-only reads)
  const since = new Date(Date.now() - 30 * 864e5).toISOString();
  const [{ data: pays }, { data: statusRows }, { data: recent }, { count: openDisputes }, { count: refunds30 }] = await Promise.all([
    sb.from("payments").select("amount, created_at").eq("status", "paid").gte("created_at", since).limit(2000),
    sb.from("bookings").select("status").limit(5000),
    sb.from("bookings").select("id, scheduled_at, status, service_price, service:services(name), provider:provider_profiles(business_name), customer:profiles(full_name)").order("created_at", { ascending: false }).limit(5),
    sb.from("payments").select("id", { count: "exact", head: true }).eq("dispute_status", "open"),
    sb.from("payments").select("id", { count: "exact", head: true }).eq("status", "refunded").gte("created_at", since),
  ]);
  const dayKey = (d) => new Date(d).toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
  const perDay = new Map();
  for (let i = 29; i >= 0; i--) perDay.set(dayKey(Date.now() - i * 864e5), 0);
  (pays ?? []).forEach((x) => { const k = dayKey(x.created_at); if (perDay.has(k)) perDay.set(k, perDay.get(k) + Number(x.amount)); });
  const paid30 = [...perDay.values()].reduce((s, v) => s + v, 0);
  const max = Math.max(1, ...perDay.values());
  const chart = `<svg viewBox="0 0 300 110" class="bars" role="img" aria-label="Card payments per day, last 30 days: ${esc(money(paid30))} total">${
    [...perDay.entries()].map(([k, v], i) => `<rect x="${i * 10 + 1}" y="${100 - (v / max) * 96}" width="8" height="${Math.max(v ? 2 : 0.5, (v / max) * 96)}" rx="2" fill="${v ? "var(--brand-600)" : "var(--tint)"}"><title>${esc(k)}: ${esc(money(v))}</title></rect>`).join("")
  }<text x="0" y="109" font-size="7" fill="var(--muted)">${esc([...perDay.keys()][0].slice(5))}</text><text x="300" y="109" font-size="7" text-anchor="end" fill="#64748b">${esc([...perDay.keys()].at(-1).slice(5))}</text></svg>`;
  const mix = {}; (statusRows ?? []).forEach((r) => { mix[r.status] = (mix[r.status] ?? 0) + 1; });
  const total = (statusRows ?? []).length || 1;
  const COLORS = { pending: "#f59e0b", confirmed: "#3b82f6", in_progress: "#6366f1", completed: "#16a34a", cancelled: "#ef4444", declined: "#94a3b8" };
  const statusBars = Object.keys(BOOKING_LABEL).map((s) => `<div class="sbar"><span>${esc(BOOKING_LABEL[s])}</span><div><i style="width:${((mix[s] ?? 0) / total) * 100}%;background:${COLORS[s]}"></i></div><b>${mix[s] ?? 0}</b></div>`).join("");
  const latest = (recent ?? []).length ? recent.map((b) => `<div class="sched"><strong>${esc(dateOnly(b.scheduled_at))}</strong><span>${esc(b.customer?.full_name || "Customer")} → ${esc(b.provider?.business_name ?? "Provider")} · ${esc(b.service?.name ?? "Service")}</span><b>${esc(money(b.service_price))}</b>${pill(b.status === "pending" ? "review" : b.status, BOOKING_LABEL[b.status] ?? b.status)}</div>`).join("") : `<div class="muted small">No bookings yet.</div>`;

  body.innerHTML = `
    ${pendingProviders ? `<div class="alert alert-warn"><strong>${pendingProviders}</strong> provider${pendingProviders > 1 ? "s are" : " is"} waiting for approval.
      <a class="link" href="admin.html?tab=providers&status=pending">Review now →</a></div>` : ""}
    <div class="stats">
      <div class="stat"><div class="num">${users}</div><div class="lbl">Users</div></div>
      <div class="stat"><div class="num">${providers}</div><div class="lbl">Providers</div></div>
      <div class="stat"><div class="num">${services}</div><div class="lbl">Services</div></div>
      <div class="stat"><div class="num">${bookings}</div><div class="lbl">Bookings (${pendingBookings} pending)</div></div>
    </div>
    <div class="stats" style="grid-template-columns:repeat(2,1fr)">
      <div class="stat"><div class="num">${money(gross)}</div><div class="lbl">Completed bookings value</div></div>
      <div class="stat stat-accent"><div class="num">${money(fees)}</div><div class="lbl">Platform fees earned</div></div>
    </div>
    <div class="stats" style="grid-template-columns:repeat(3,1fr)">
      <div class="stat"><div class="num">${money(paid30)}</div><div class="lbl">Card payments, last 30 days</div></div>
      <div class="stat"><div class="num">${openDisputes}</div><div class="lbl"><a class="link" href="admin.html?tab=disputes">Open disputes</a></div></div>
      <div class="stat"><div class="num">${refunds30}</div><div class="lbl">Refunds, last 30 days</div></div>
    </div>
    <div class="ov-grid">
      <div class="panel"><h3 style="margin:0 0 4px">Card payments, last 30 days</h3><p class="hint" style="margin:0 0 8px">Paid amounts by day (Dallas time).</p>${chart}</div>
      <div class="panel"><h3 style="margin:0 0 12px">Bookings by status</h3>${statusBars}</div>
    </div>
    <div class="panel" style="margin-top:16px"><h3 style="margin:0 0 12px">Latest bookings</h3>${latest}
      <p style="margin:12px 0 0"><a class="link small" href="admin.html?tab=bookings">See all bookings →</a></p></div>
    <p class="hint">Fees are calculated per booking when it is created: ${esc(pct(settings.free_fee_percent))} on the Free plan, ${esc(pct(settings.pro_fee_percent))} for Wasel Pro providers. <a class="link" href="admin.html?tab=settings">Change fees →</a></p>`;
}

// ---------------------------------------------------------------- providers
async function tabProviders(body) {
  const { data, error } = await sb
    .from("provider_profiles")
    .select("id, business_name, description, phone, email, city, state, zip_code, status, commission_rate, is_pro, business_type, categories, years_experience, languages, website, rating, review_count, created_at, owner:profiles(full_name), areas:provider_service_areas(kind, label), private:provider_private(license_info, referral_source, terms_accepted_at)")
    .order("created_at", { ascending: false });
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load providers: ${esc(friendlyMessage(error.message))}</div>`);

  const all = data ?? [];
  const [{ data: extras }, { data: docRows }] = await Promise.all([
    sb.rpc("admin_provider_extras"),
    sb.from("provider_documents").select("id, provider_id, kind, file_name, storage_path").is("service_id", null).order("created_at"),
  ]);
  const byApp = new Map((extras ?? []).map((x) => [x.provider_id, x]));
  const byDocs = new Map();
  for (const d of docRows ?? []) byDocs.set(d.provider_id, [...(byDocs.get(d.provider_id) ?? []), d]);
  for (const p of all) { p.app = byApp.get(p.id) ?? null; p.docs = byDocs.get(p.id) ?? []; }
  const wanted = params().get("status");
  const status = ["pending", "approved", "suspended", "all"].includes(wanted) ? wanted : "pending";
  const counts = (st) => all.filter((p) => p.status === st).length;
  const filters = [["pending", "Waiting"], ["approved", "Approved"], ["suspended", "Suspended"], ["all", "All"]];
  const shown = status === "all" ? all : all.filter((p) => p.status === status);

  body.innerHTML = `
    <div class="pills">${filters.map(([k, l]) =>
      `<a class="pill-link ${k === status ? "active" : ""}" href="admin.html?tab=providers&status=${k}">${l} (${k === "all" ? all.length : counts(k)})</a>`).join("")}</div>
    <div id="msg" hidden></div>
    ${shown.length ? shown.map(providerCard).join("") : `<div class="empty">Nothing here.</div>`}`;

  body.addEventListener("click", async (e) => {
    const dv = e.target.closest("[data-view-doc]");
    if (dv) { const err = await openDoc(dv.dataset.viewDoc); if (err) showMessage(document.getElementById("msg"), err); return; }
    const ep = e.target.closest("[data-edit-provider]");
    if (ep) {
      const p = all.find((x) => x.id === ep.closest("[data-id]").dataset.id);
      const out = await askForm({ title: `Edit ${p.business_name}`, text: "Changes the business details customers see. The location and service areas are not changed here.",
        fields: [{ label: "Business name", value: p.business_name ?? "", max: 120, required: true }, { label: "Description", value: p.description ?? "", rows: 4, max: 2000 },
                 { label: "Phone", value: p.phone ?? "", max: 40, type: "tel" }, { label: "Email", value: p.email ?? "", max: 200, type: "email" }, { label: "Website", value: p.website ?? "", max: 300, type: "url" }] });
      if (!out) return;
      ep.disabled = true;
      const [bn, ds, ph, em, wb] = out.values;
      const { error } = await sb.rpc("admin_update_provider", { p_provider_id: p.id, p_business_name: bn, p_description: ds, p_phone: ph, p_email: em, p_website: wb, p_reason: out.reason });
      if (error) { ep.disabled = false; return showMessage(document.getElementById("msg"), friendlyMessage(error.message)); }
      return location.reload();
    }
    const rv = e.target.closest("[data-review]");
    if (rv) {
      const card = rv.closest("[data-id]"), act = rv.dataset.review, name = card.dataset.name;
      let note = null;
      if (act === "approve") { if (!confirm(`Approve ${name}? They will become visible to customers.`)) return; }
      else {
        note = await askReason(act === "reject"
          ? { title: "Reject this application?", text: "The provider will receive your reason by email and on their dashboard.", confirm: "Reject", danger: true }
          : { title: "Ask for more information?", text: "Say exactly what is missing (a document, a clearer photo, a detail). The provider gets your message by email, answers, and sends the application again.", confirm: "Send request" });
        if (!note) return;
      }
      rv.disabled = true;
      const { error } = await sb.rpc("admin_review_provider", { p_provider_id: card.dataset.id, p_action: act, p_note: note });
      if (error) { rv.disabled = false; return showMessage(document.getElementById("msg"), friendlyMessage(error.message)); }
      await kickEmails(); // tells the provider
      location.reload();
      return;
    }
    const btn = e.target.closest("[data-set]");
    if (!btn) return;
    const to = btn.dataset.set;
    const name = btn.closest("[data-id]").dataset.name;
    const ask = { approved: `Approve ${name}? They will become visible to customers.`, suspended: `Suspend ${name}? Customers will no longer see them or be able to book.` }[to];
    if (ask && !confirm(ask)) return;
    btn.disabled = true;
    const { error } = await sb.rpc("admin_set_provider_status", { p_provider_id: btn.closest("[data-id]").dataset.id, p_status: to });
    if (error) { btn.disabled = false; return showMessage(document.getElementById("msg"), error.message); }
    location.reload();
  });
}

function providerCard(p) {
  const APP_LABEL = { submitted: "Waiting for your review", needs_info: "Waiting for the provider's answer", rejected: "Rejected", approved: "Approved" };
  const buttons = {
    pending: [],
    approved: [["suspended", "Suspend", "btn-danger"]],
    suspended: [["approved", "Reinstate", ""]],
  }[p.status] ?? [];
  return `
  <article class="card svc" data-id="${esc(p.id)}" data-name="${esc(p.business_name)}">
    <div class="top">
      <div><h3>${esc(p.business_name)}${p.is_pro ? ' <span class="badge completed">Pro</span>' : ""}</h3>
        <div class="meta">Owner: ${esc(p.owner?.full_name || "—")} · applied ${esc(dateOnly(p.created_at))}</div></div>
      ${pill(p.status, PROVIDER_LABEL[p.status] ?? p.status)}
    </div>
    ${p.description ? `<p class="small" style="margin:12px 0 0;color:var(--text-2)">${esc(p.description)}</p>` : ""}
    <dl class="kv">
      <div><dt>Location</dt><dd>${esc([p.city, p.state, p.zip_code].filter(Boolean).join(", ") || "—")}</dd></div>
      <div class="wide"><dt>Serves</dt><dd>${p.areas?.length ? p.areas.map((a) => esc(a.label)).join(", ") : '<span class="muted">No service areas yet</span>'}</dd></div>
      <div><dt>Works as</dt><dd>${p.business_type ? (p.business_type === "company" ? "Company" : "Individual") : "—"}${p.years_experience != null ? ` · ${esc(p.years_experience)} yrs` : ""}</dd></div>
      <div class="wide"><dt>Services</dt><dd>${p.categories?.length ? p.categories.map((c) => esc(CATEGORY_LABEL[c] ?? c)).join(", ") : "—"}</dd></div>
      <div><dt>Languages</dt><dd>${p.languages?.length ? p.languages.map(esc).join(", ") : "—"}</dd></div>
      <div><dt>Website</dt><dd>${p.website && /^https?:\/\//i.test(p.website) ? `<a class="link" href="${esc(p.website)}" target="_blank" rel="noopener noreferrer nofollow">${esc(p.website)}</a>` : "—"}</dd></div>
      <div class="wide"><dt>License / insurance (private)</dt><dd>${p.private?.license_info ? esc(p.private.license_info) : '<span class="muted">Not provided</span>'}</dd></div>
      <div><dt>Heard about us</dt><dd>${esc(REFERRAL_LABEL[p.private?.referral_source] ?? "—")}</dd></div>
      <div><dt>Terms accepted</dt><dd>${p.private?.terms_accepted_at ? esc(dateOnly(p.private.terms_accepted_at)) : '<span class="muted">No record</span>'}</dd></div>
      <div><dt>Contact</dt><dd>${esc([p.phone, p.email].filter(Boolean).join(" · ") || "—")}</dd></div>
      <div><dt>Fee / rating</dt><dd>${esc(p.commission_rate)}% · ${p.review_count ? `★ ${Number(p.rating).toFixed(1)} (${p.review_count})` : "no reviews"}</dd></div>
    </dl>
    <div class="field" style="margin-top:12px"><div class="small muted" style="margin-bottom:6px">Documents</div>
      ${p.docs?.length ? `<ul class="doc-list">${p.docs.map((d) => `<li><span class="doc-kind">${esc(KIND_LABEL[d.kind] ?? d.kind)}</span><span class="doc-name">${esc(d.file_name)}</span><button type="button" class="btn btn-sm btn-outline" data-view-doc="${esc(d.storage_path)}">View</button></li>`).join("")}</ul>` : `<span class="muted small">No documents uploaded</span>`}</div>
    ${p.status === "pending" && p.app ? `<div class="small" style="margin-top:8px"><strong>Application:</strong> ${esc(APP_LABEL[p.app.state] ?? p.app.state)}${p.app.note ? ` — “${esc(p.app.note)}”` : ""}</div>` : ""}
    <div class="btn-row" style="margin-top:16px">${p.status === "pending"
      ? `<button class="btn btn-sm" data-review="approve">Approve</button><button class="btn btn-sm btn-outline" data-review="request_info">Ask for more info</button><button class="btn btn-sm btn-danger" data-review="reject">Reject</button>`
      : buttons.map(([to, label, cls]) => `<button class="btn btn-sm ${cls}" data-set="${to}">${label}</button>`).join("")}${IS_SUPER ? `<button class="btn btn-sm btn-outline" data-edit-provider>Edit details</button>` : ""}</div>
  </article>`;
}

// ---------------------------------------------------------------- users
const ROLE_LABEL = { customer: "Customer", provider: "Provider", admin: "Admin" };
const datetime = (iso) => (iso ? formatDateTime(iso) : "never");

// Everyone, with email, status and last sign-in. Falls back to the plain list if the admin upgrade SQL is not installed yet.
async function loadUsers() {
  const r = await sb.rpc("admin_users_overview", { p_limit: 1000 });
  if (!r.error) return { users: r.data ?? [], full: true };
  const old = await sb.from("profiles").select("id, full_name, phone, role, is_active, created_at").order("created_at", { ascending: false }).limit(300);
  if (old.error) return { error: old.error };
  return { users: old.data ?? [], full: false };
}

async function tabUsers(body, me) {
  const res = await loadUsers();
  if (res.error) return (body.innerHTML = `<div class="alert alert-error">Could not load users: ${esc(friendlyMessage(res.error.message))}</div>`);
  const { users, full } = res;
  let roleFilter = "all";

  body.innerHTML = `
    <div class="pills" id="role-pills">${[["all", "Everyone"], ["customer", "Customers"], ["provider", "Providers"], ["admin", "Admins"]]
      .map(([k, l]) => `<button type="button" class="pill-link ${k === "all" ? "active" : ""}" data-role-filter="${k}">${l}</button>`).join("")}</div>
    <div class="toolbar"><input id="find" type="search" placeholder="Search by name, email or phone" aria-label="Search users"><span class="muted small" id="count"></span></div>
    ${full ? "" : `<div class="alert alert-warn">Emails, sign-in dates and editing need the admin upgrade (run <code>wasel-admin-upgrade.sql</code> once). Showing the basic list.</div>`}
    <div id="msg" hidden></div>
    <div id="user-list"></div>`;

  const list = document.getElementById("user-list");
  const draw = () => {
    const t = document.getElementById("find").value.trim().toLowerCase();
    const rows = users.filter((u) => (roleFilter === "all" || u.role === roleFilter)
      && (!t || [u.full_name, u.phone, u.email, u.business_name].some((x) => (x ?? "").toLowerCase().includes(t))));
    document.getElementById("count").textContent = `${rows.length} user${rows.length === 1 ? "" : "s"}`;
    list.innerHTML = rows.length ? rows.map((u) => userRow(u, me, full)).join("") : `<div class="empty">No matching users.</div>`;
  };
  draw();
  document.getElementById("find").addEventListener("input", draw);
  document.getElementById("role-pills").addEventListener("click", (e) => {
    const b = e.target.closest("[data-role-filter]");
    if (!b) return;
    roleFilter = b.dataset.roleFilter;
    for (const x of document.querySelectorAll("#role-pills .pill-link")) x.classList.toggle("active", x === b);
    draw();
  });

  list.addEventListener("click", async (e) => {
    const msg = document.getElementById("msg");
    const edit = e.target.closest("[data-edit-user]");
    if (edit) {
      const u = users.find((x) => x.id === edit.closest("[data-id]").dataset.id);
      const out = await askForm({ title: `Edit ${u.full_name || "this user"}`, text: "Changes the name and phone shown on their account. The email is managed by the login system and is not changed here.",
        fields: [{ label: "Full name", value: u.full_name ?? "", max: 120, required: true }, { label: "Phone", value: u.phone ?? "", max: 40, type: "tel" }] });
      if (!out) return;
      edit.disabled = true;
      const { error } = await sb.rpc("admin_update_user", { p_user_id: u.id, p_full_name: out.values[0], p_phone: out.values[1], p_reason: out.reason });
      if (error) { edit.disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
      return location.reload();
    }
    const act = e.target.closest("[data-active]");
    if (act) {
      const row = act.closest("[data-id]"); const on = act.dataset.active === "1"; const who = row.dataset.name || "this user";
      const reason = await askReason(on
        ? { title: `Reactivate ${who}?`, text: "They will be able to book, review and manage their account again. A provider stays suspended until you approve them in Providers.", confirm: "Reactivate" }
        : { title: `Deactivate ${who}?`, text: "They can no longer book, review, edit services or change bookings. A provider's business is suspended and disappears from search. They can still write to us from the Contact page.", confirm: "Deactivate", danger: true });
      if (!reason) return;
      act.disabled = true;
      const { error } = await sb.rpc("admin_set_user_active", { p_user_id: row.dataset.id, p_active: on, p_reason: reason });
      if (error) { act.disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
      return location.reload();
    }
    const btn = e.target.closest("[data-save-role]");
    if (!btn) return;
    const row = btn.closest("[data-id]");
    const role = row.querySelector("select").value;
    if (!confirm(`Change ${row.dataset.name || "this user"}'s role to "${role}"?`)) return;
    btn.disabled = true;
    const { error } = await sb.rpc("admin_set_user_role", { p_user_id: row.dataset.id, p_role: role });
    if (error) { btn.disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
    location.reload();
  });
}

function userRow(u, me, full) {
  const isMe = u.id === me.id;
  const manageable = !isMe && !u.is_super_admin && (IS_SUPER || u.role !== "admin"); // the database enforces the same rule
  const roles = IS_SUPER ? ["customer", "provider", "admin"] : ["customer", "provider"];
  const opts = roles.map((r) => `<option value="${r}" ${r === u.role ? "selected" : ""}>${ROLE_LABEL[r]}</option>`).join("");
  const provider = u.provider_status ? `${pill(u.provider_status, PROVIDER_LABEL[u.provider_status] ?? u.provider_status)}` : "";
  const meta = [u.email, u.phone || "no phone", `joined ${dateOnly(u.created_at)}`, full ? `last sign-in ${datetime(u.last_sign_in_at)}` : null,
    full && u.role !== "admin" ? `${u.bookings_count ?? 0} booking${Number(u.bookings_count) === 1 ? "" : "s"}` : null].filter(Boolean);
  return `
  <div class="card row-card" data-id="${esc(u.id)}" data-name="${esc(u.full_name ?? "")}">
    <div class="info"><div class="name">${esc(u.full_name || "(no name)")} ${isMe ? '<span class="muted small">(you)</span>' : ""}</div>
      <div class="muted small">${meta.map(esc).join(" · ")}</div>
      ${u.business_name ? `<div class="small" style="margin-top:2px">Business: ${esc(u.business_name)}</div>` : ""}</div>
    ${u.is_super_admin ? pill("admin", "Main admin") : pill(u.role, ROLE_LABEL[u.role] ?? u.role)}
    ${provider}
    ${u.is_active === false ? pill("suspended", "Deactivated") : pill("approved", "Active")}
    ${full ? (u.email_confirmed ? "" : pill("pending", "Email not confirmed")) : ""}
    <div class="btn-row">
      ${IS_SUPER && full ? `<button class="btn btn-sm btn-outline" data-edit-user>Edit</button>` : ""}
      ${manageable ? `<select aria-label="Role">${opts}</select><button class="btn btn-sm btn-outline" data-save-role>Save</button>
        ${u.is_active === false ? `<button class="btn btn-sm" data-active="1">Reactivate</button>` : `<button class="btn btn-sm btn-danger" data-active="0">Deactivate</button>`}`
        : `<span class="muted small">${isMe ? "You can't change your own account" : u.is_super_admin ? "The main admin can't be changed" : "Only the main admin can manage admins"}</span>`}
    </div>
  </div>`;
}

// ---------------------------------------------------------------- admins (main admin only)
const INVITE_LABEL = { active: ["approved", "Active"], used: ["completed", "Used"], revoked: ["declined", "Cancelled"], expired: ["draft", "Expired"] };

async function tabAdmins(body, me) {
  const [inv, ov] = await Promise.all([sb.rpc("admin_list_invites"), sb.rpc("admin_users_overview", { p_limit: 1000 })]);
  if (inv.error || ov.error) return (body.innerHTML = `<div class="alert alert-error">Could not load admins: ${esc(friendlyMessage((inv.error || ov.error).message))}. Make sure <code>wasel-admin-upgrade.sql</code> was run.</div>`);
  const admins = (ov.data ?? []).filter((u) => u.role === "admin");
  const invites = inv.data ?? [];

  body.innerHTML = `
    <section class="panel">
      <h2>Invite a new admin</h2>
      <p class="small muted">Create a one-time code and give it to the person. On the <strong>Admin log in</strong> page they choose “I have an invite code”, fill the form and confirm their email. Each code works once and then stops working.</p>
      <form id="invite-form" class="toolbar" style="margin-top:12px">
        <input id="inv-note" type="text" maxlength="120" placeholder="Who is it for? (optional note)" aria-label="Note">
        <select id="inv-days" aria-label="Valid for">${[[1, "1 day"], [3, "3 days"], [7, "7 days"], [14, "14 days"], [30, "30 days"]].map(([d, l]) => `<option value="${d}" ${d === 7 ? "selected" : ""}>Valid ${l}</option>`).join("")}</select>
        <button class="btn" type="submit">Create invite code</button>
      </form>
      <div id="inv-msg" hidden></div>
      <div id="inv-code" hidden></div>
    </section>
    <h2 class="section-title" style="margin-top:28px">Invite codes</h2>
    <div id="inv-list">${invites.length ? invites.map(inviteRow).join("") : `<div class="empty">No invite codes yet.</div>`}</div>
    <h2 class="section-title" style="margin-top:28px">Current admins (${admins.length})</h2>
    ${admins.map((u) => `<div class="card row-card"><div class="info"><div class="name">${esc(u.full_name || "(no name)")}${u.id === me.id ? ' <span class="muted small">(you)</span>' : ""}</div>
      <div class="muted small">${[u.email, `last sign-in ${datetime(u.last_sign_in_at)}`].map(esc).join(" · ")}</div></div>
      ${u.is_super_admin ? pill("admin", "Main admin") : pill("admin", "Admin")}${u.is_active ? pill("approved", "Active") : pill("suspended", "Deactivated")}</div>`).join("")}
    <p class="hint">To remove an admin or change their details, open the Users tab. Only you, the main admin, can do that.</p>`;

  const msg = document.getElementById("inv-msg"), codeBox = document.getElementById("inv-code");
  document.getElementById("invite-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    showMessage(msg, ""); codeBox.hidden = true;
    const btn = e.target.querySelector("button[type=submit]"); btn.disabled = true;
    const { data, error } = await sb.rpc("admin_create_invite", { p_note: document.getElementById("inv-note").value.trim() || null, p_days: Number(document.getElementById("inv-days").value) });
    btn.disabled = false;
    if (error) return showMessage(msg, friendlyMessage(error.message));
    codeBox.hidden = false;
    codeBox.className = "alert alert-ok";
    codeBox.innerHTML = `<div class="small"><strong>Copy this code now.</strong> It is shown only once and works for one person.</div>
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:8px"><code id="inv-code-text" style="font-size:1.05rem;word-break:break-all">${esc(data.code)}</code><button type="button" class="btn btn-sm btn-outline" id="copy-code">Copy</button></div>
      <div class="small muted" style="margin-top:6px">Valid until ${esc(formatDateTime(data.expires_at))}</div>`;
    document.getElementById("copy-code").onclick = async (ev) => {
      try { await navigator.clipboard.writeText(data.code); ev.target.textContent = "Copied"; } catch { ev.target.textContent = "Select and copy it by hand"; }
    };
    document.getElementById("inv-note").value = "";
    const list = await sb.rpc("admin_list_invites");
    if (!list.error) document.getElementById("inv-list").innerHTML = (list.data ?? []).map(inviteRow).join("");
  });

  document.getElementById("inv-list").addEventListener("click", async (e) => {
    const b = e.target.closest("[data-revoke]");
    if (!b) return;
    if (!confirm("Cancel this invite code? It will stop working immediately.")) return;
    b.disabled = true;
    const { error } = await sb.rpc("admin_revoke_invite", { p_id: b.dataset.revoke });
    if (error) { b.disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
    location.reload();
  });
}

function inviteRow(i) {
  const [cls, label] = INVITE_LABEL[i.status] ?? ["draft", i.status];
  return `<div class="card row-card"><div class="info"><div class="name">${esc(i.note || "Invite code")}</div>
    <div class="muted small">${[`created ${dateOnly(i.created_at)}`, i.status === "used" ? `used by ${i.used_by_name || "a new admin"}` : `valid until ${dateOnly(i.expires_at)}`].map(esc).join(" · ")}</div></div>
    ${pill(cls, label)}${i.status === "active" ? `<button class="btn btn-sm btn-danger" data-revoke="${esc(i.id)}">Cancel code</button>` : ""}</div>`;
}

// ---------------------------------------------------------------- bookings
async function tabBookings(body) {
  const { data, error } = await sb
    .from("bookings")
    .select("id, scheduled_at, status, service_price, platform_commission, provider_payout, service:services(name), provider:provider_profiles(business_name), customer:profiles(full_name)")
    .order("scheduled_at", { ascending: false })
    .limit(100);
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load bookings: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  body.innerHTML = `<p class="hint">Showing the latest 100 bookings. You can cancel one that is not finished yet: the customer is refunded in full if they paid, and both sides get an email.</p><div id="msg-bookings" class="alert" hidden></div>` +
    (rows.length ? rows.map((b) => `
    <div class="card row-card" data-booking="${esc(b.id)}">
      <div class="info"><div class="name">${esc(b.service?.name ?? "Service")}</div>
        <div class="muted small">${esc(b.customer?.full_name || "Customer")} → ${esc(b.provider?.business_name ?? "Provider")} · ${esc(formatDateTime(b.scheduled_at))}</div></div>
      <div class="small"><strong>${money(b.service_price)}</strong> <span class="muted">(fee ${money(b.platform_commission)})</span></div>
      ${pill(b.status === "pending" ? "review" : b.status, BOOKING_LABEL[b.status] ?? b.status)}
      ${["pending", "confirmed", "in_progress"].includes(b.status) ? `<button class="btn btn-sm btn-danger" data-cancel-booking="${esc(b.id)}">Cancel booking</button>` : ""}
    </div>`).join("") : `<div class="empty">No bookings yet.</div>`);
  body.onclick = async (e) => {
    const btn = e.target.closest("[data-cancel-booking]");
    if (!btn) return;
    const msg = document.getElementById("msg-bookings");
    const reason = await askReason({ title: "Cancel this booking?", text: "Both people are emailed. If the customer already paid, they are refunded in full.", confirm: "Cancel booking", danger: true });
    if (!reason) return;
    btn.disabled = true;
    const { error: err } = await sb.rpc("admin_cancel_booking", { p_booking_id: btn.dataset.cancelBooking, p_reason: reason });
    if (err) { btn.disabled = false; return showMessage(msg, err.message); }
    let note = "Cancelled.";
    const { data: pay } = await sb.from("payments").select("status").eq("booking_id", btn.dataset.cancelBooking).maybeSingle();
    if (pay?.status === "paid") try { const r = await callFunction("process-refund", { booking_id: btn.dataset.cancelBooking }); if (r.status === "refunded") note = "Cancelled and the customer was refunded in full."; else if (r.status === "failed") note = "Cancelled, but the refund failed. Retry it from the booking or refund in Stripe."; else if (r.status === "disputed") note = "Cancelled. The payment is disputed, so it cannot be refunded here."; }
    catch { note = "Cancelled, but the refund could not be started. The customer paid, so refund the payment (Stripe Dashboard or try again)."; }
    await kickEmails();
    showMessage(msg, note, "ok");
    setTimeout(() => location.reload(), 1800);
  };
}

// ---------------------------------------------------------------- disputes
const DISPUTE_LABEL = { open: "Open", lost: "Lost", won: "Won" };
async function tabDisputes(body) {
  const { data, error } = await sb.rpc("admin_disputes");
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load disputes: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  body.innerHTML = `<p class="hint">A dispute is when a customer asks their bank to take a payment back. While it is open (and if it is lost) the provider is not paid and we cannot refund it. Reply to open disputes in the Stripe Dashboard (Payments → Disputes) before the deadline.</p>` +
    (rows.length ? rows.map((d) => `
    <div class="card row-card" data-dispute="${esc(d.payment_id)}">
      <div class="info"><div class="name">${esc(d.service_name)}</div>
        <div class="muted small">${esc(d.customer_name || "Customer")} → ${esc(d.provider_name)} · opened ${esc(dateOnly(d.disputed_at))}</div>
        ${d.payout_already_sent ? `<div class="small" style="color:var(--danger);margin-top:4px"><strong>The provider was already paid.</strong> Wasel carries this loss unless it is recovered from the provider.</div>` : ""}</div>
      <div class="small"><strong>${money(d.amount)}</strong></div>
      ${pill(d.dispute_status === "open" ? "review" : d.dispute_status === "lost" ? "suspended" : "approved", DISPUTE_LABEL[d.dispute_status] ?? d.dispute_status)}
    </div>`).join("") : `<div class="empty">No disputes. Good news.</div>`);
}

// ---------------------------------------------------------------- problems reported by customers
async function tabProblems(body) {
  const { data, error } = await sb.rpc("admin_problems");
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load problems: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  body.innerHTML = `<p class="hint">A customer said a completed job was not done properly. The provider is not paid while a problem is open. Talk to both sides, then press <strong>Release payout</strong> if the provider should be paid. If the customer should get money back instead, refund the payment by hand in the Stripe Dashboard and leave the payout held.</p><div id="msg-problems" class="alert" hidden></div>` +
    (rows.length ? rows.map((r) => `
    <div class="card row-card" data-problem="${esc(r.booking_id)}">
      <div class="info"><div class="name">${esc(r.service_name)} · ${esc(money(r.price))}</div>
        <div class="muted small">${esc(r.customer_name || "Customer")} → ${esc(r.business_name)} · reported ${esc(dateOnly(r.reported_at))} · ${r.paid ? "paid" : "not paid"}${r.payout_status === "sent" ? " · <strong>payout already sent</strong>" : ""}</div>
        <div class="small" style="margin-top:6px;white-space:pre-wrap">${esc(r.note)}</div></div>
      <button class="btn btn-sm" data-resolve="${esc(r.booking_id)}">Release payout</button>
    </div>`).join("") : `<div class="empty">No open problems.</div>`);
  body.onclick = async (e) => {
    const btn = e.target.closest("[data-resolve]");
    if (!btn) return;
    if (!confirm("Release the provider's payout for this job?")) return;
    btn.disabled = true;
    const { error: err } = await sb.rpc("admin_resolve_problem", { p_booking_id: btn.dataset.resolve });
    if (err) { btn.disabled = false; return showMessage(document.getElementById("msg-problems"), err.message); }
    showMessage(document.getElementById("msg-problems"), "Released. The payout is sent within a few minutes.", "ok");
    setTimeout(() => location.reload(), 1500);
  };
}

// ---------------------------------------------------------------- messages from the Contact page
const TOPIC_LABEL = { general: "General", booking: "Booking", payment: "Payment or refund", provider: "Provider", account: "Account", privacy: "Privacy / data", other: "Other" };
async function tabMessages(body) {
  const show = params().get("show") === "handled" ? "handled" : "new";
  const { data, error } = await sb.rpc("admin_contact_messages", { p_status: show });
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load messages: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  body.innerHTML = `<div class="pills"><a class="pill-link ${show === "new" ? "active" : ""}" href="admin.html?tab=messages">New</a><a class="pill-link ${show === "handled" ? "active" : ""}" href="admin.html?tab=messages&show=handled">Handled</a></div>
    <p class="hint">Reply from your own email to the address shown, then press <strong>Mark handled</strong>.</p><div id="msg-contact" class="alert" hidden></div>` +
    (rows.length ? rows.map((m) => `
    <div class="card row-card" data-msg="${esc(m.id)}">
      <div class="info"><div class="name">${esc(m.name)} · <a class="link" href="mailto:${esc(m.email)}">${esc(m.email)}</a></div>
        <div class="muted small">${esc(TOPIC_LABEL[m.topic] ?? m.topic)} · ${esc(formatDateTime(m.created_at))}${m.is_member ? " · has an account" : ""}</div>
        <div class="small" style="margin-top:6px;white-space:pre-wrap">${esc(m.message)}</div></div>
      <button class="btn btn-sm btn-outline" data-handled="${esc(m.id)}" data-to="${show === "new" ? "1" : "0"}">${show === "new" ? "Mark handled" : "Reopen"}</button>
    </div>`).join("") : `<div class="empty">${show === "new" ? "No new messages." : "Nothing handled yet."}</div>`);
  body.onclick = async (e) => {
    const btn = e.target.closest("[data-handled]");
    if (!btn) return;
    btn.disabled = true;
    const { error: err } = await sb.rpc("admin_contact_handled", { p_id: btn.dataset.handled, p_handled: btn.dataset.to === "1" });
    if (err) { btn.disabled = false; return showMessage(document.getElementById("msg-contact"), err.message); }
    location.reload();
  };
}

// ---------------------------------------------------------------- content: hide services, remove reviews
async function tabContent(body) {
  const { data, error } = await sb.rpc("admin_content", { p_limit: 100 });
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load content: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  const svcs = rows.filter((r) => r.kind === "service"), revs = rows.filter((r) => r.kind === "review");
  const svcRow = (r) => `<div class="card row-card" data-svc="${esc(r.id)}">
      <div class="info"><div class="name">${esc(r.title)}</div><div class="muted small">${esc(r.subtitle)} · added ${esc(dateOnly(r.created_at))}</div>
        ${r.body ? `<div class="small" style="margin-top:6px">${esc(r.body)}</div>` : ""}</div>
      ${pill(r.status === "active" ? "approved" : r.status === "inactive" ? "suspended" : "draft", r.status === "inactive" ? "hidden" : r.status)}
      ${r.status === "draft" ? "" : r.status === "active" ? `<button class="btn btn-sm btn-danger" data-hide="${esc(r.id)}">Hide</button>` : `<button class="btn btn-sm" data-show="${esc(r.id)}">Show</button>`}
    </div>`;
  const revRow = (r) => `<div class="card row-card" data-rev="${esc(r.id)}">
      <div class="info"><div class="name"><span class="stars">${esc(r.title)}</span></div><div class="muted small">${esc(r.subtitle)} · ${esc(dateOnly(r.created_at))}</div>
        ${r.body ? `<div class="small" style="margin-top:6px;white-space:pre-wrap">${esc(r.body)}</div>` : ""}</div>
      <button class="btn btn-sm btn-danger" data-remove-review="${esc(r.id)}">Remove</button>
    </div>`;
  body.innerHTML = `<p class="hint">Hide a service that breaks the rules (the provider keeps it, customers stop seeing it). Remove a review that is abusive or fake. Both need a reason and are saved in Activity.</p><div id="msg-content" class="alert" hidden></div>
    <h3 style="margin:16px 0 8px">Services (${svcs.length})</h3>${svcs.length ? svcs.map(svcRow).join("") : `<div class="empty">No services yet.</div>`}
    <h3 style="margin:24px 0 8px">Reviews (${revs.length})</h3>${revs.length ? revs.map(revRow).join("") : `<div class="empty">No reviews yet.</div>`}`;
  body.onclick = async (e) => {
    const b = e.target.closest("[data-hide],[data-show],[data-remove-review]");
    if (!b) return;
    const msg = document.getElementById("msg-content");
    let reason, call;
    if (b.dataset.hide || b.dataset.show) {
      const hide = !!b.dataset.hide;
      reason = await askReason(hide
        ? { title: "Hide this service?", text: "Customers will no longer see it or be able to book it. Existing bookings are not changed.", confirm: "Hide", danger: true }
        : { title: "Show this service again?", text: "It becomes visible and bookable again.", confirm: "Show" });
      call = () => sb.rpc("admin_set_service_status", { p_service_id: b.dataset.hide || b.dataset.show, p_status: hide ? "inactive" : "active", p_reason: reason });
    } else {
      reason = await askReason({ title: "Remove this review?", text: "It disappears for everyone and the provider's rating is recalculated. This cannot be undone.", confirm: "Remove review", danger: true });
      call = () => sb.rpc("admin_remove_review", { p_review_id: b.dataset.removeReview, p_reason: reason });
    }
    if (!reason) return;
    b.disabled = true;
    const { error: err } = await call();
    if (err) { b.disabled = false; return showMessage(msg, err.message); }
    location.reload();
  };
}

// ---------------------------------------------------------------- activity log
const ACTION_TEXT = {
  provider_status: (d) => `set the business “${d.business ?? "?"}” from ${d.from} to ${d.to}`,
  user_role: (d) => `changed the role of ${d.name || "a user"} from ${d.from} to ${d.to}`,
  problem_released: () => "released the payout after a reported problem",
  user_deactivated: (d) => `deactivated ${d.name || "a user"} (${d.role})${d.provider_suspended ? " and suspended their business" : ""}`,
  user_reactivated: (d) => `reactivated ${d.name || "a user"} (${d.role})`,
  service_hidden: (d) => `hid the service “${d.name ?? "?"}”`,
  service_shown: (d) => `showed the service “${d.name ?? "?"}” again`,
  review_removed: (d) => `removed a ${d.rating}-star review${d.comment ? `: “${d.comment}”` : ""}`,
  service_approved: (d) => `approved the service “${d.name ?? "?"}” (${money(d.price)})`,
  service_rejected: (d) => `rejected the service “${d.name ?? "?"}”`,
  catalog_added: (d) => `added “${d.name ?? "?"}” to the services list`,
  catalog_updated: (d) => `changed “${d.name ?? "?"}” in the services list`,
  catalog_hidden: (d) => `hid “${d.name ?? "?"}” from the services list`,
  catalog_shown: (d) => `showed “${d.name ?? "?"}” in the services list again`,
  catalog_deleted: (d) => `deleted “${d.name ?? "?"}” from the services list`,
  fees_changed: (d) => `changed the platform fees: Free ${pct(d.free_from)} → ${pct(d.free_to)}, Pro ${pct(d.pro_from)} → ${pct(d.pro_to)} (${d.providers_updated} provider${d.providers_updated === 1 ? "" : "s"} updated)`,
  pro_price_changed: (d) => `changed the Wasel Pro price from ${dollars(d.from_cents)} to ${dollars(d.to_cents)} per month`,
  booking_cancelled: (d) => `cancelled a ${d.was} booking (${money(d.price)})`,
  provider_approved: (d) => `approved the provider “${d.business ?? "?"}”`,
  provider_rejected: (d) => `rejected the application of “${d.business ?? "?"}”`,
  provider_info_requested: (d) => `asked “${d.business ?? "?"}” for more information`,
  service_info_requested: (d) => `asked for more information about the service “${d.name ?? "?"}”`,
  alert_dismissed: (d) => `dismissed the rating alert for “${d.business ?? "?"}” (average ${d.avg}, ${d.reviews} reviews)`,
  alert_provider_suspended: (d) => `suspended “${d.business ?? "?"}” after a rating alert (average ${d.avg}, ${d.reviews} reviews)`,
  rating_policy_changed: (d) => `changed the rating alert policy: minimum reviews ${d.min_reviews?.[0]} → ${d.min_reviews?.[1]}, average below ${d.max_avg?.[0]} → ${d.max_avg?.[1]}`,
};
async function tabActivity(body) {
  const { data, error } = await sb.rpc("admin_audit_log", { p_limit: 200 });
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load the activity log: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  body.innerHTML = `<p class="hint">Every admin action, newest first. Nobody can edit or delete this log. Showing the latest 200.</p>` +
    (rows.length ? rows.map((r) => `
    <div class="card row-card" data-audit="${esc(r.id)}">
      <div class="info"><div><strong>${esc(r.admin_name)}</strong> ${esc((ACTION_TEXT[r.action] ?? (() => r.action))(r.details ?? {}))}</div>
        ${r.reason ? `<div class="small" style="margin-top:4px">Reason: ${esc(r.reason)}</div>` : ""}
        <div class="muted small">${esc(formatDateTime(r.created_at))}</div></div>
    </div>`).join("") : `<div class="empty">No admin actions yet.</div>`);
}

// ---------------------------------------------------------------- start (kept at the END so every const above is ready)
if (!user) {
  location.replace("admin-login.html");
} else {
  await init(user);
}


// ---------------------------------------------------------------- services catalog (the list providers choose from)
async function tabCatalog(body) {
  const { data, error } = await sb.rpc("admin_catalog_list");
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load the services list: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  const catOpts = (sel) => CATEGORIES.map((c) => `<option value="${esc(c.slug)}" ${c.slug === sel ? "selected" : ""}>${esc(c.label)}</option>`).join("");
  const fields = (r = {}) => `
    <div class="field"><label>Service name</label><input name="name" required minlength="2" maxlength="80" value="${esc(r.name ?? "")}"></div>
    <div class="field"><label>Description</label><textarea name="description" rows="2" maxlength="500">${esc(r.description ?? "")}</textarea></div>
    <div class="row3">
      <div class="field"><label>Category</label><select name="category">${catOpts(r.category ?? "car_detailing")}</select></div>
      <div class="field"><label>Suggested price (USD, optional)</label><input name="suggested_price" type="number" min="1" max="100000" step="0.01" value="${esc(r.suggested_price ?? "")}"></div>
      <div class="field"><label>Default duration (minutes)</label><input name="default_duration_minutes" type="number" min="15" max="1440" step="5" required value="${esc(r.default_duration_minutes ?? 60)}"></div>
    </div>`;
  const readFields = (f) => ({
    p_name: f.name.value.trim(), p_description: f.description.value.trim() || null, p_category: f.category.value,
    p_suggested_price: f.suggested_price.value === "" ? null : Number(f.suggested_price.value), p_duration: parseInt(f.default_duration_minutes.value, 10),
  });
  const row = (r) => `<div class="card" data-cat="${esc(r.id)}" style="margin-top:12px">
      <div class="top"><div><h3>${esc(r.name)}</h3>
        <div class="muted small">${esc(CATEGORY_LABEL[r.category] ?? r.category)} · ${r.suggested_price != null ? esc(money(r.suggested_price)) + " suggested" : "no suggested price"} · ${esc(r.default_duration_minutes)} min · offered by ${esc(r.offered_by)} provider${Number(r.offered_by) === 1 ? "" : "s"}</div></div>
        ${pill(r.is_active ? "approved" : "suspended", r.is_active ? "Shown" : "Hidden")}</div>
      ${r.description ? `<p class="small" style="margin:10px 0 0;color:var(--text-2)">${esc(r.description)}</p>` : ""}
      <div class="btn-row" style="margin-top:12px">
        <button class="btn btn-sm btn-outline" data-cat-act="edit">Edit</button>
        <button class="btn btn-sm ${r.is_active ? "btn-danger" : ""}" data-cat-act="${r.is_active ? "hide" : "show"}">${r.is_active ? "Hide" : "Show"}</button>
        ${Number(r.offered_by) === 0 ? `<button class="btn btn-sm btn-danger" data-cat-act="delete">Delete</button>` : ""}
      </div>
      <form class="edit-form" hidden style="margin-top:12px">${fields(r)}
        <div class="field"><label>Why are you changing it?</label><input name="reason" required minlength="5" maxlength="500"></div>
        <div class="edit-msg" hidden></div><button class="btn btn-sm" type="submit">Save changes</button></form>
    </div>`;
  const cats = CATEGORIES.map((c) => [c, rows.filter((r) => r.category === c.slug)]).filter(([, l]) => l.length);
  body.innerHTML = `<p class="hint">This is the list of services on Wasel. Providers can only choose from it and set their own price. A change here is copied to every provider who offers the service. Hiding a service takes it off the site and stops new bookings; bookings that already exist are not affected.</p>
    <div id="msg-catalog" class="alert" hidden></div>
    <details class="add-box" id="cat-add" ${rows.length ? "" : "open"}><summary class="btn">+ Add a service</summary>
      <form id="cat-add-form" style="margin-top:12px">${fields()}<div id="cat-add-msg" hidden></div><button class="btn" type="submit">Add to the list</button></form></details>
    <h2 class="section-title">Services (${rows.length})</h2>
    ${cats.length ? cats.map(([c, list]) => `<h3 class="small muted" style="margin:16px 0 8px">${esc(c.icon)} ${esc(c.label)}</h3>${list.map(row).join("")}`).join("") : `<div class="empty">No services yet. Add the first one above.</div>`}`;

  document.getElementById("cat-add-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = e.target, msg = document.getElementById("cat-add-msg"), btn = f.querySelector("button[type=submit]");
    btn.disabled = true;
    const { error: er } = await sb.rpc("admin_create_catalog_item", readFields(f));
    if (er) { btn.disabled = false; return showMessage(msg, friendlyMessage(er.message)); }
    location.reload();
  });
  body.addEventListener("submit", async (e) => {
    const f = e.target.closest(".edit-form");
    if (!f) return;
    e.preventDefault();
    const card = f.closest("[data-cat]"), msg = f.querySelector(".edit-msg"), btn = f.querySelector("button[type=submit]");
    const cur = rows.find((r) => r.id === card.dataset.cat);
    btn.disabled = true;
    const { error: er } = await sb.rpc("admin_update_catalog_item", { p_id: card.dataset.cat, ...readFields(f), p_active: cur.is_active, p_reason: f.reason.value.trim() });
    if (er) { btn.disabled = false; return showMessage(msg, friendlyMessage(er.message)); }
    location.reload();
  });
  body.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-cat-act]");
    if (!b) return;
    const card = b.closest("[data-cat]"), act = b.dataset.catAct, cur = rows.find((r) => r.id === card.dataset.cat);
    const msg = document.getElementById("msg-catalog");
    if (act === "edit") { const f = card.querySelector(".edit-form"); f.hidden = !f.hidden; return; }
    let er;
    if (act === "delete") {
      const note = await askReason({ title: `Delete “${cur.name}”?`, text: "Nobody offers this service, so it is removed from the list for good. Write why.", confirm: "Delete", danger: true });
      if (!note) return;
      b.disabled = true;
      ({ error: er } = await sb.rpc("admin_delete_catalog_item", { p_id: cur.id, p_reason: note }));
    } else {
      const hide = act === "hide";
      const note = await askReason(hide
        ? { title: `Hide “${cur.name}”?`, text: `Customers will no longer see or book this service${Number(cur.offered_by) ? ` from the ${cur.offered_by} provider${Number(cur.offered_by) === 1 ? "" : "s"} who offer it` : ""}. Bookings that already exist are not affected. Write why.`, confirm: "Hide", danger: true }
        : { title: `Show “${cur.name}” again?`, text: "Providers can choose it again and customers can see it. Write why.", confirm: "Show" });
      if (!note) return;
      b.disabled = true;
      ({ error: er } = await sb.rpc("admin_update_catalog_item", { p_id: cur.id, p_name: cur.name, p_description: cur.description, p_category: cur.category,
        p_suggested_price: cur.suggested_price, p_duration: cur.default_duration_minutes, p_active: !hide, p_reason: note }));
    }
    if (er) { b.disabled = false; return showMessage(msg, friendlyMessage(er.message)); }
    location.reload();
  });
}

// ---------------------------------------------------------------- alerts (too many low ratings)
async function tabAlerts(body) {
  const [{ data, error }, { data: pol }] = await Promise.all([sb.rpc("admin_alerts_list"), sb.rpc("admin_rating_policy")]);
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load the alerts: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [], p0 = (pol ?? [])[0];
  const open = rows.filter((a) => a.status === "open"), done = rows.filter((a) => a.status !== "open");
  const ids = open.map((a) => a.provider_id);
  const { data: revs } = ids.length ? await sb.from("reviews").select("provider_id, rating, comment, created_at").in("provider_id", ids).order("created_at", { ascending: false }).limit(200) : { data: [] };
  const revsOf = (id) => (revs ?? []).filter((r) => r.provider_id === id).slice(0, 5);
  const stars = (n) => "★".repeat(n) + "☆".repeat(5 - n);
  body.innerHTML = `<p class="hint">When a provider has ${p0 ? esc(p0.min_reviews) : "several"} or more reviews and an average below ${p0 ? esc(Number(p0.max_avg).toFixed(1)) : "the limit"}, an alert appears here and you get an email. Nothing happens automatically: you decide whether to leave the provider as is or suspend them. <a class="link" href="admin.html?tab=settings">Change the limits →</a></p>
    <div id="msg-alerts" class="alert" hidden></div>
    <h2 class="section-title">Open (${open.length})</h2>
    ${open.length ? open.map((a) => `
    <div class="card" data-alert="${esc(a.id)}" data-name="${esc(a.business_name)}">
      <div class="top"><div><h3>${esc(a.business_name)}</h3><div class="muted small">Average <strong>★ ${esc(Number(a.avg_rating).toFixed(2))}</strong> from ${esc(a.review_count)} reviews · alert on ${esc(dateOnly(a.created_at))} · ${esc(PROVIDER_LABEL[a.provider_status] ?? a.provider_status)}</div></div>${pill("review", "Open")}</div>
      <div style="margin-top:10px"><div class="small muted" style="margin-bottom:4px">Latest reviews</div>
        ${revsOf(a.provider_id).map((r) => `<div class="small" style="margin-bottom:4px"><span style="color:var(--warm)">${stars(r.rating)}</span> ${r.comment ? esc(r.comment) : '<span class="muted">No comment</span>'}</div>`).join("") || '<span class="muted small">No reviews</span>'}</div>
      <div class="btn-row" style="margin-top:12px"><button class="btn btn-sm btn-outline" data-alert-act="dismiss">Dismiss, no action</button>${a.provider_status === "approved" ? `<button class="btn btn-sm btn-danger" data-alert-act="suspend">Suspend provider</button>` : ""}</div>
    </div>`).join("") : `<div class="empty">No open alerts. 🎉</div>`}
    ${done.length ? `<h2 class="section-title" style="margin-top:24px">Handled</h2>${done.map((a) => `
    <div class="card row-card"><div class="info"><div><strong>${esc(a.business_name)}</strong> <span class="muted small">· ★ ${esc(Number(a.avg_rating).toFixed(2))} (${esc(a.review_count)})</span></div>
      <div class="small">${a.action === "suspended" ? "Suspended" : "Dismissed"}${a.note ? `: ${esc(a.note)}` : ""}</div>
      <div class="muted small">${a.handled_at ? esc(dateOnly(a.handled_at)) : ""}</div></div></div>`).join("")}` : ""}`;
  body.onclick = async (e) => {
    const b = e.target.closest("[data-alert-act]");
    if (!b) return;
    const card = b.closest("[data-alert]"), act = b.dataset.alertAct;
    const note = await askReason(act === "suspend"
      ? { title: `Suspend ${card.dataset.name}?`, text: "Customers will no longer see or book this provider. You can reinstate them later from the Providers tab.", confirm: "Suspend", danger: true }
      : { title: "Dismiss this alert?", text: "The provider stays as they are. Write why no action is needed.", confirm: "Dismiss" });
    if (!note) return;
    b.disabled = true;
    const { error: err } = await sb.rpc("admin_handle_alert", { p_alert_id: card.dataset.alert, p_action: act, p_note: note });
    if (err) { b.disabled = false; return showMessage(document.getElementById("msg-alerts"), friendlyMessage(err.message)); }
    location.reload();
  };
}

// ---------------------------------------------------------------- settings (fees and Pro price)
async function tabSettings(body) {
  const draw = async (flash) => {
    const { data, error } = await sb.rpc("public_settings");
    if (error || !data?.[0]) return (body.innerHTML = `<div class="alert alert-error">Could not load the settings: ${esc(friendlyMessage(error?.message ?? "no data"))}</div>`);
    const s = data[0];
    const pol = ((await sb.rpc("admin_rating_policy")).data ?? [])[0];
    body.innerHTML = `
      <p class="hint">Changes are saved in Activity with your reason. They apply to <strong>new</strong> bookings and subscriptions only: a booking keeps the fee it was made with.</p>
      <div id="msg-settings" class="alert ${flash ? "alert-ok" : ""}" ${flash ? "" : "hidden"}>${esc(flash ?? "")}</div>
      <section class="panel" style="margin-top:16px">
        <h3 style="margin:0 0 4px">Platform fee</h3>
        <p class="small muted" style="margin:0 0 12px">Taken from each booking. Providers on the Free plan pay the Free fee; providers on Wasel Pro pay the Pro fee.</p>
        <form id="fees-form" class="row3" novalidate>
          <div class="field"><label for="fee-free">Free plan fee (%)</label><input id="fee-free" type="number" min="0" max="50" step="0.01" required value="${esc(Number(s.free_fee_percent))}"></div>
          <div class="field"><label for="fee-pro">Wasel Pro fee (%)</label><input id="fee-pro" type="number" min="0" max="50" step="0.01" required value="${esc(Number(s.pro_fee_percent))}"></div>
          <div class="field" style="align-self:end"><button class="btn" type="submit" id="fees-save">Save fees</button></div>
        </form>
        <div id="fees-err" class="alert alert-error" hidden></div>
      </section>
      <section class="panel" style="margin-top:16px">
        <h3 style="margin:0 0 4px">Wasel Pro monthly price</h3>
        <p class="small muted" style="margin:0 0 12px">Current price: <strong>${esc(dollars(s.pro_price_cents))}</strong> per month. A new price is used for providers who subscribe from now on; people who already subscribe keep the price they signed up at.</p>
        <form id="price-form" class="row3" novalidate>
          <div class="field"><label for="pro-price">New monthly price (USD)</label><input id="pro-price" type="number" min="1" max="1000" step="0.01" required value="${esc((Number(s.pro_price_cents) / 100).toFixed(2))}"></div>
          <div class="field" style="align-self:end"><button class="btn" type="submit" id="price-save">Save price</button></div>
        </form>
        <div id="price-err" class="alert alert-error" hidden></div>
      </section>
      <section class="panel" style="margin-top:16px">
        <h3 style="margin:0 0 4px">Low-rating alerts</h3>
        <p class="small muted" style="margin:0 0 12px">When a provider has at least this many reviews and an average below the limit, you get an alert (Alerts tab) and an email. Nothing is suspended automatically.</p>
        <form id="policy-form" class="row3" novalidate>
          <div class="field"><label for="pol-min">Minimum number of reviews</label><input id="pol-min" type="number" min="1" max="100" step="1" required value="${esc(Number(pol?.min_reviews ?? 5))}"></div>
          <div class="field"><label for="pol-avg">Alert when the average is below</label><input id="pol-avg" type="number" min="1" max="5" step="0.1" required value="${esc(Number(pol?.max_avg ?? 3).toFixed(1))}"></div>
          <div class="field" style="align-self:end"><button class="btn" type="submit" id="policy-save">Save limits</button></div>
        </form>
        <div id="policy-err" class="alert alert-error" hidden></div>
      </section>`;

    document.getElementById("fees-form").onsubmit = async (e) => {
      e.preventDefault();
      const err = document.getElementById("fees-err"); err.hidden = true;
      const free = Number(document.getElementById("fee-free").value), pro = Number(document.getElementById("fee-pro").value);
      if (!Number.isFinite(free) || !Number.isFinite(pro) || free < 0 || free > 50 || pro < 0 || pro > 50) return showMessage(err, "Fees must be between 0% and 50%.");
      if (pro > free) return showMessage(err, "The Pro fee cannot be higher than the Free fee.");
      if (free === Number(s.free_fee_percent) && pro === Number(s.pro_fee_percent)) return showMessage(err, "These are already the current fees.");
      const reason = await askReason({ title: "Change the platform fees?", text: `Free ${pct(s.free_fee_percent)} → ${pct(free)}, Pro ${pct(s.pro_fee_percent)} → ${pct(pro)}. New bookings use the new fees; existing bookings keep theirs.`, confirm: "Change fees" });
      if (!reason) return;
      const btn = document.getElementById("fees-save"); btn.disabled = true;
      const { data: n, error: rerr } = await sb.rpc("admin_update_fees", { p_free: free, p_pro: pro, p_reason: reason });
      if (rerr) { btn.disabled = false; return showMessage(err, friendlyMessage(rerr.message)); }
      await draw(`Fees updated: Free ${pct(free)}, Pro ${pct(pro)} (${n} provider${n === 1 ? "" : "s"} updated).`);
    };

    document.getElementById("policy-form").onsubmit = async (e) => {
      e.preventDefault();
      const err = document.getElementById("policy-err"); err.hidden = true;
      const min = Number(document.getElementById("pol-min").value), avg = Number(document.getElementById("pol-avg").value);
      if (!Number.isInteger(min) || min < 1 || min > 100) return showMessage(err, "The minimum number of reviews must be a whole number from 1 to 100.");
      if (!Number.isFinite(avg) || avg < 1 || avg > 5) return showMessage(err, "The average must be between 1 and 5.");
      if (min === Number(pol.min_reviews) && avg === Number(pol.max_avg)) return showMessage(err, "These are already the current limits.");
      const reason = await askReason({ title: "Change the alert limits?", text: `Alert at ${min}+ reviews with an average below ${avg.toFixed(1)}. Existing alerts are not changed.`, confirm: "Save limits" });
      if (!reason) return;
      const btn = document.getElementById("policy-save"); btn.disabled = true;
      const { error: rerr } = await sb.rpc("admin_update_rating_policy", { p_min: min, p_max: avg, p_reason: reason });
      if (rerr) { btn.disabled = false; return showMessage(err, friendlyMessage(rerr.message)); }
      await draw(`Alert limits saved: ${min}+ reviews, average below ${avg.toFixed(1)}.`);
    };

    document.getElementById("price-form").onsubmit = async (e) => {
      e.preventDefault();
      const err = document.getElementById("price-err"); err.hidden = true;
      const cents = Math.round(Number(document.getElementById("pro-price").value) * 100);
      if (!Number.isInteger(cents) || cents < 100 || cents > 100000) return showMessage(err, "The monthly price must be between $1 and $1,000.");
      if (cents === Number(s.pro_price_cents)) return showMessage(err, "That is already the current price.");
      const reason = await askReason({ title: "Change the Wasel Pro price?", text: `${dollars(s.pro_price_cents)} → ${dollars(cents)} per month for new subscribers. Current subscribers are not changed.`, confirm: "Change price" });
      if (!reason) return;
      const btn = document.getElementById("price-save"); btn.disabled = true;
      try {
        await callFunction("admin-set-pro-price", { cents, reason });
      } catch (ex) { btn.disabled = false; return showMessage(err, ex.message); }
      await draw(`Wasel Pro now costs ${dollars(cents)} per month for new subscribers.`);
    };
  };
  await draw();
}
