import { mountAreaEditor } from "./areas.js";
import { mountProviderForm } from "./provider-form.js";
import { mountDocs, mountDocQueue, uploadDoc, uploadDocWithId, removeDocById } from "./docs.js";
import { chatBox, mountChats, mountWorkPhotos, lastHour, mapsUrl } from "./serviceday.js";
import { photoFromCamera, setInputFile } from "./capture.js";
import { getRole, callFunction, kickEmails, sb, renderChrome, esc, money, formatDateTime, params, showMessage, CATEGORIES, categoryLabel, PHOTO_BUCKET, MAX_PHOTOS, sortPhotos, photoUrl, prepareImage , friendlyMessage, getSettings, pct, dollars, icon, adoptTabs } from "./app.js";

const TZ = "America/Chicago";
const root = document.getElementById("provider");
const user = await renderChrome();

const pill = (cls, label) => `<span class="badge ${esc(cls)}">${esc(label)}</span>`;
const PROVIDER_LABEL = { pending: "Waiting for approval", approved: "Approved", suspended: "Suspended" };
const BOOKING_LABEL = { pending: "New request", confirmed: "Confirmed", in_progress: "In progress", completed: "Completed", cancelled: "Cancelled", declined: "Declined" };

async function init(user) {
  if ((await getRole(user.id)) === "admin") return location.replace("admin.html");
  const { data: provider, error } = await sb.from("provider_profiles").select("*").eq("user_id", user.id).maybeSingle();
  if (error) {
    root.innerHTML = `<div class="alert alert-error">Could not load your provider profile: ${esc(friendlyMessage(error.message))}</div>`;
  } else if (!provider) {
    renderRegister(user);
  } else {
    await renderDashboard(provider);
  }
}

// ============================================================ register: the same form the sign-up page uses (without the account step)
function renderRegister(user) {
  mountProviderForm(root, { user, afterDone: () => location.reload() });
}

// ============================================================ dashboard shell
async function renderDashboard(provider) {
  const { data: areaRows } = await sb.from("provider_service_areas").select("label").eq("provider_id", provider.id);
  provider.areas = (areaRows ?? []).map((a) => a.label).sort((x, y) => x.localeCompare(y));
  const areaWarn = sessionStorage.getItem("areaWarn"); sessionStorage.removeItem("areaWarn");
  const docWarn = sessionStorage.getItem("docWarn"); sessionStorage.removeItem("docWarn");
  const { data: app } = await sb.from("provider_applications").select("state, note").eq("provider_id", provider.id).maybeSingle();
  provider.app = app ?? { state: provider.status === "pending" ? "submitted" : "approved", note: null };
  const tab = ["overview", "bookings", "services", "profile"].includes(params().get("tab")) ? params().get("tab") : "overview";
  const { count: pendingCount } = await sb.from("bookings").select("id", { count: "exact", head: true }).eq("provider_id", provider.id).eq("status", "pending");
  const tabs = [["overview", "Overview", "dashboard"], ["bookings", "Bookings", "calendar"], ["services", "Services", "wrench"], ["profile", "Business profile", "settings"]];

  const banner =
    provider.status === "pending" && provider.app.state === "needs_info"
      ? `<div class="alert alert-warn"><strong>Wasel needs more information.</strong> ${esc(provider.app.note ?? "")}<br><span class="small">Update your profile or upload documents in <a class="link" href="provider.html?tab=profile">Business profile</a>, then send your application again.</span>
          <div style="margin-top:8px"><button class="btn btn-sm" id="resubmit-app" type="button">Send application again</button></div><div id="resubmit-msg" hidden></div></div>`
    : provider.status === "pending" && provider.app.state === "rejected"
      ? `<div class="alert alert-error"><strong>Your application was not approved.</strong> ${esc(provider.app.note ?? "")}<br><span class="small">If you think this is a mistake, please contact us.</span></div>`
    : provider.status === "pending"
      ? `<div class="alert alert-warn">Your application is waiting for approval. Customers cannot see you until an admin approves it — you can finish your business profile in the meantime.</div>`
      : provider.status === "suspended"
        ? `<div class="alert alert-error">Your account is suspended. Customers cannot see your services or book you. Contact support.</div>`
        : "";
  const docBanner = docWarn
    ? `<div class="alert alert-error">Your application was sent, but ${esc(docWarn)} document${docWarn === "1" ? "" : "s"} could not be uploaded. Add ${docWarn === "1" ? "it" : "them"} again in the <a class="link" href="provider.html?tab=profile">Business profile</a> tab.</div>`
    : "";
  const areaBanner = areaWarn
    ? `<div class="alert alert-error">Your application was sent, but your service areas could not be saved (${esc(areaWarn)}). Add them in the Business profile tab.</div>`
    : provider.areas.length === 0
      ? `<div class="alert alert-warn">You have not chosen where you work yet. Customers search by city or ZIP code, so add at least one service area in the <a class="link" href="provider.html?tab=profile">Business profile</a> tab.</div>`
      : "";

  root.innerHTML = `
    <div class="head-row">
      <h1 style="font-size:1.875rem">${esc(provider.business_name)}</h1>
      ${pill(provider.status, PROVIDER_LABEL[provider.status] ?? provider.status)}
    </div>
    ${banner}${docBanner}${areaBanner}
    <div class="dash">
      <nav class="tabs" aria-label="Provider dashboard">${tabs.map(([k, l, i]) => `<a class="tab ${k === tab ? "active" : ""}" href="provider.html?tab=${k}" data-tab="${k}">${icon(i)}<span>${l}</span>${k === "bookings" && pendingCount ? ` <span class="count">${pendingCount}</span>` : ""}</a>`).join("")}</nav>
      <div id="tab-body"><p class="muted loading" style="margin-top:24px">Loading…</p></div>
    </div>`;

  adoptTabs();
  document.getElementById("resubmit-app")?.addEventListener("click", async (e) => {
    e.currentTarget.disabled = true;
    const { error } = await sb.rpc("resubmit_application");
    if (error) { e.currentTarget.disabled = false; return showMessage(document.getElementById("resubmit-msg"), friendlyMessage(error.message)); }
    await kickEmails();
    location.reload();
  });
  const body = document.getElementById("tab-body");
  if (tab === "overview") await tabOverview(provider, body);
  if (tab === "bookings") await tabBookings(provider, body);
  if (tab === "services") await tabServices(provider, body);
  if (tab === "profile") tabProfile(provider, body);
}

// ============================================================ overview tab
async function tabOverview(provider, body) {
  const [{ data: bk }, { data: svcs }, { data: photoRows }] = await Promise.all([
    sb.from("bookings").select("id, scheduled_at, status, service_price, provider_payout, service:services(name), customer:profiles(full_name)").eq("provider_id", provider.id).order("scheduled_at", { ascending: true }),
    sb.from("services").select("id, status").eq("provider_id", provider.id),
    sb.from("service_photos").select("service_id"),
  ]);
  const rows = bk ?? [], services = svcs ?? [];
  const payoutOn = ((await sb.rpc("my_payout_status")).data ?? [])[0]?.payouts_enabled === true;
  const day = (iso) => new Date(iso).toLocaleDateString(window.waselLocale, { timeZone: TZ });
  const monthKey = (iso) => new Date(iso).toLocaleDateString(window.waselLocale, { timeZone: TZ, month: "numeric", year: "numeric" });
  const now = new Date().toISOString(), today = day(now), thisMonth = monthKey(now);
  const pending = rows.filter((r) => r.status === "pending");
  const todays = rows.filter((r) => ["confirmed", "in_progress"].includes(r.status) && day(r.scheduled_at) === today);
  const earned = rows.filter((r) => r.status === "completed" && monthKey(r.scheduled_at) === thisMonth).reduce((s, r) => s + Number(r.provider_payout), 0);
  const time = (iso) => new Date(iso).toLocaleTimeString(window.waselLocale, { timeZone: TZ, hour: "numeric", minute: "2-digit" });
  const withPhotos = new Set((photoRows ?? []).map((x) => x.service_id));
  const todo = [
    [services.length > 0, "Add your first service", "provider.html?tab=services"],
    [services.length > 0 && services.every((s) => withPhotos.has(s.id)), "Add photos to every service", "provider.html?tab=services"],
    [provider.areas.length > 0, "Choose the areas you serve", "provider.html?tab=profile"],
    [payoutOn, "Set up payouts to get paid", "provider.html?tab=profile#payout-box"],
  ];
  if (provider.status === "pending") {
    const { data: dk } = await sb.from("provider_documents").select("kind").eq("provider_id", provider.id).is("service_id", null);
    const kinds = new Set((dk ?? []).map((d) => d.kind));
    todo.unshift([kinds.has("id") && (kinds.has("license") || kinds.has("insurance")), "Upload your ID and a license or proof of insurance", "provider.html?tab=profile"]);
  }
  const open = todo.filter(([ok]) => !ok);

  const promo = open.length && provider.status === "approved"
    ? `<div class="promo"><div><div class="promo-eyebrow">Next step</div><h3>Finish setting up your profile</h3><p>A complete profile gets you more bookings.</p></div><a class="btn" href="${open[0][2]}">Continue</a></div>`
    : "";
  body.innerHTML = `
    ${promo}
    <div class="stats">
      <a class="stat stat-link" href="provider.html?tab=bookings#upcoming"><div class="num">${todays.length}</div><div class="lbl">Today's jobs</div></a>
      <a class="stat stat-link" href="provider.html?tab=bookings#new"><div class="num">${pending.length}</div><div class="lbl">New requests</div></a>
      <a class="stat stat-link stat-accent" href="provider.html?tab=bookings#history"><div class="num">${money(earned)}</div><div class="lbl">Earned this month</div></a>
      <a class="stat stat-link" href="provider.html?tab=profile"><div class="num">${provider.review_count ? "★ " + Number(provider.rating).toFixed(1) : "—"}</div><div class="lbl">${provider.review_count ? `Rating (${provider.review_count})` : "No reviews yet"}</div></a>
    </div>
    <div class="ov-grid">
      <div class="panel"><h3 style="margin:0 0 4px">Today's schedule</h3><p class="hint" style="margin:0 0 12px">Confirmed and in-progress jobs for today.</p>
        ${todays.length ? todays.map((b) => `<a class="sched" href="provider.html?tab=bookings#upcoming"><strong>${esc(time(b.scheduled_at))}</strong><span>${esc(b.customer?.full_name || "Customer")} · ${esc(b.service?.name ?? "Service")}</span>${pill(b.status, BOOKING_LABEL[b.status])}</a>`).join("") : `<div class="muted small">Nothing scheduled for today.</div>`}
        ${pending.length ? `<p style="margin:16px 0 0"><a class="btn btn-sm" href="provider.html?tab=bookings">Review ${pending.length} new request${pending.length > 1 ? "s" : ""}</a></p>` : ""}
      </div>
      <div class="panel"><h3 style="margin:0 0 4px">Get set up</h3>
        ${open.length ? `<ul class="todo">${open.map(([, l, href]) => `<li><a class="link" href="${href}">${esc(l)} →</a></li>`).join("")}</ul>` : `<div class="small">✅ Your profile is complete.</div>`}
        <p style="margin:16px 0 0"><a class="btn btn-sm btn-outline" href="provider.html?tab=services">+ Add a service</a></p>
      </div>
    </div>`;
}

// ============================================================ bookings tab
async function tabBookings(provider, body) {
  const { data, error } = await sb
    .from("bookings")
    .select("id, scheduled_at, status, service_price, platform_commission, provider_payout, customer_address, customer_city, customer_zip_code, customer_notes, confirmed_at, started_at, arrived_at, service:services(name), customer:profiles(full_name, phone)")
    .eq("provider_id", provider.id)
    .order("scheduled_at", { ascending: true });

  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load bookings: ${esc(friendlyMessage(error.message))}</div>`);
  const rows = data ?? [];
  const { data: distRows } = await sb.rpc("my_booking_distances");
  const miles = new Map((distRows ?? []).map((d) => [d.booking_id, Number(d.miles)]));
  // the customer's average rating from other providers, and what I already rated
  const { data: crRows } = await sb.rpc("customer_ratings_for_my_bookings");
  const custRating = new Map((crRows ?? []).map((r) => [r.booking_id, r]));
  const { data: mineRows } = await sb.from("customer_reviews").select("booking_id, rating, comment");
  const myRatings = new Map((mineRows ?? []).map((r) => [r.booking_id, r]));
  // payout state per booking (null if payments are not set up yet: the page still works)
  const payoutRows = (await sb.rpc("my_booking_payouts")).data ?? [];
  const payouts = new Map(payoutRows.map((x) => [x.booking_id, x]));
  const payoutOn = ((await sb.rpc("my_payout_status")).data ?? [])[0]?.payouts_enabled === true;
  const card = (b) => bookingCard(b, payouts.get(b.id), payoutOn, miles.get(b.id), custRating.get(b.id), myRatings.get(b.id));

  const day = (iso) => new Date(iso).toLocaleDateString(window.waselLocale, { timeZone: TZ });
  const today = day(new Date().toISOString());
  const pending = rows.filter((r) => r.status === "pending");
  const upcoming = rows.filter((r) => ["confirmed", "in_progress"].includes(r.status));
  const history = rows.filter((r) => ["completed", "cancelled", "declined"].includes(r.status)).reverse();
  const done = rows.filter((r) => r.status === "completed");
  const todayCount = upcoming.filter((r) => day(r.scheduled_at) === today).length;
  const revenue = done.reduce((sum, r) => sum + Number(r.provider_payout), 0);

  body.innerHTML = `
    <div class="stats">
      <a class="stat stat-link" href="#new"><div class="num">${pending.length}</div><div class="lbl">New requests</div></a>
      <a class="stat stat-link" href="#upcoming"><div class="num">${todayCount}</div><div class="lbl">Today's jobs</div></a>
      <a class="stat stat-link" href="#history"><div class="num">${done.length}</div><div class="lbl">Completed jobs</div></a>
      <a class="stat stat-link stat-accent" href="#history"><div class="num">${money(revenue)}</div><div class="lbl">Earned (after fees)</div></a>
    </div>
    ${section("New requests", pending, "No new requests right now.", card, "new")}
    ${section("Upcoming & in progress", upcoming, "Nothing scheduled.", card, "upcoming")}
    ${section("History", history, "No past jobs yet.", card, "history")}
    <div id="bk-msg" hidden></div>`;
  mountChats(body, provider.user_id, "Customer");
  if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
  body.querySelectorAll("[data-workphotos]").forEach((el) => mountWorkPhotos(el, { userId: provider.user_id, bookingId: el.dataset.workphotos, editable: true }));

  body.addEventListener("submit", async (e) => {
    const f = e.target.closest(".rate-cust");
    if (!f) return;
    e.preventDefault();
    const msg = f.querySelector(".rate-msg"), rating = Number(f.rating.value);
    if (!(rating >= 1 && rating <= 5)) return showMessage(msg, "Choose a rating from 1 to 5 stars.");
    f.querySelector("button").disabled = true;
    const { error } = await sb.from("customer_reviews").insert({ booking_id: f.closest("[data-id]").dataset.id, rating, comment: f.comment.value.trim() || null });
    if (error) { f.querySelector("button").disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
    location.reload();
  });

  body.addEventListener("click", async (e) => {
    const payBtn = e.target.closest("[data-payout]");
    if (payBtn) {
      const msg = document.getElementById("bk-msg");
      payBtn.disabled = true;
      try {
        const out = await callFunction("release-payout", { booking_id: payBtn.closest("[data-id]").dataset.id });
        if (out.status === "no_account") throw new Error("Set up your payout account first (Business profile tab).");
        if (out.status === "failed") throw new Error("The payout could not be sent. Try again in a moment.");
        location.reload();
      } catch (err) { payBtn.disabled = false; showMessage(msg, err.message); }
      return;
    }
    const arr = e.target.closest("[data-arrived]");
    if (arr) {
      arr.disabled = true;
      const { error } = await sb.rpc("mark_arrived", { p_booking_id: arr.closest("[data-id]").dataset.id });
      if (error) { arr.disabled = false; return showMessage(document.getElementById("bk-msg"), error.message); }
      return location.reload();
    }
    const btn = e.target.closest("[data-to]");
    if (!btn) return;
    const msg = document.getElementById("bk-msg");
    const to = btn.dataset.to;
    if ((to === "declined" || to === "cancelled") && !confirm(waselT(to === "declined" ? "Decline this request?" : "Cancel this booking?"))) return;
    btn.disabled = true;
    const { error } = await sb.rpc("transition_booking", { p_booking_id: btn.closest("[data-id]").dataset.id, p_new_status: to });
    if (error) { btn.disabled = false; return showMessage(msg, error.message); }
    if (to === "declined" || to === "cancelled") await callFunction("process-refund", { booking_id: btn.closest("[data-id]").dataset.id }).catch(() => {}); // returns the customer's money if they had paid
    if (to === "completed") await callFunction("release-payout", { booking_id: btn.closest("[data-id]").dataset.id }).catch(() => {}); // best effort; the card shows the state
    await kickEmails();
    location.reload();
  });
}

// the provider rates the customer once the job is completed and the customer confirmed it
function rateCustomer(b, mine) {
  if (mine) return `<div class="small" style="margin-top:10px">You rated this customer <span style="color:var(--warm)">${"★".repeat(mine.rating)}${"☆".repeat(5 - mine.rating)}</span>${mine.comment ? ` · “${esc(mine.comment)}”` : ""}</div>`;
  if (b.status !== "completed") return "";
  if (!b.confirmed_at) return `<div class="muted small" style="margin-top:10px">You can rate this customer once they confirm the job is done.</div>`;
  return `<form class="rate-cust" style="margin-top:12px">
    <div class="small muted" style="margin-bottom:6px">Rate this customer (the customer does not see your comment)</div>
    <div class="btn-row" style="align-items:center">
      <select name="rating" aria-label="Rating" required><option value="">Stars…</option>${[5, 4, 3, 2, 1].map((n) => `<option value="${n}">${"★".repeat(n)} (${n})</option>`).join("")}</select>
      <input name="comment" maxlength="1000" placeholder="Comment (optional)" aria-label="Comment" style="flex:1;min-width:160px">
      <button class="btn btn-sm" type="submit">Rate customer</button></div>
    <div class="rate-msg" hidden></div></form>`;
}

function section(title, rows, emptyText, card, id = "") {
  return `<h2 class="section-title"${id ? ` id="${id}"` : ""}>${esc(title)} (${rows.length})</h2>` +
    (rows.length ? rows.map((r) => card(r)).join("") : `<div class="empty" style="margin-top:12px;padding:20px">${esc(emptyText)}</div>`);
}

function payoutLine(b, pay, payoutOn) {
  if (pay?.dispute_status === "open") return `<div class="alert alert-error" style="margin-top:10px">The customer's bank is reviewing this payment (a dispute). Your payout is on hold until it is settled.</div>`;
  if (pay?.dispute_status === "lost") return `<div class="alert alert-error" style="margin-top:10px">The customer's bank took this payment back. No payout will be sent for this booking. Contact support if you think this is wrong.</div>`;
  if (b.status !== "completed") return "";
  if (!pay || !pay.paid) return `<div class="muted small" style="margin-top:10px">Your payout is sent once the customer has paid.</div>`;
  if (pay.payout_status === "sent") return `<div class="small" style="margin-top:10px">Payout sent: ${esc(money(b.provider_payout))}</div>`;
  if (pay.payout_status === "processing") return `<div class="muted small" style="margin-top:10px">Sending your payout…</div>`;
  if (pay.problem_status === "open") return `<div class="alert alert-error" style="margin-top:10px">The customer reported a problem with this job. Your payout is on hold until Wasel support reviews it.</div>`;
  if (!pay.confirmed && pay.auto_release_at && new Date(pay.auto_release_at) > new Date()) return `<div class="muted small" style="margin-top:10px">Waiting for the customer to confirm the job is done. If they do not reply, it is confirmed automatically on ${esc(new Date(pay.auto_release_at).toLocaleDateString(window.waselLocale, { timeZone: TZ, month: "short", day: "numeric" }))} and your payout is sent.</div>`;
  return `<div class="small" style="margin-top:10px">${payoutOn ? "Payout ready to send." : 'Customer paid. <a class="link" href="provider.html?tab=profile#payout-box">Set up your payout account</a> to receive ' + esc(money(b.provider_payout)) + "."} ${pay.payout_status === "failed" ? "The last attempt failed. " : ""}${payoutOn ? '<button class="btn btn-sm" data-payout>Send payout</button>' : ""}</div>`;
}

function bookingCard(b, pay, payoutOn, mi, cr, mine) {
  const actions = {
    pending: [["confirmed", "Confirm", ""], ["declined", "Decline", "btn-outline"]],
    confirmed: [["in_progress", "Start work", ""], ...(lastHour(b.scheduled_at) ? [] : [["cancelled", "Cancel", "btn-danger"]])],
    in_progress: b.arrived_at ? [["completed", "Mark completed", ""]] : [],
  }[b.status] ?? [];
  // the day of the service: directions, "I arrived", photos of the work
  const trip = b.status === "in_progress" && !b.arrived_at
    ? `<div class="trip-box"><div class="small muted">Work started. Head to the customer, and tell us when you get there.</div>
        <div class="btn-row"><a class="btn btn-sm btn-outline" href="${esc(mapsUrl(b))}" target="_blank" rel="noopener" data-route>📍 Go to the customer's address</a>
        <button class="btn btn-sm" data-arrived type="button">I arrived at the customer's address</button></div></div>`
    : b.status === "in_progress" ? `<div class="small" style="margin-top:10px">✓ You arrived at ${esc(formatDateTime(b.arrived_at))}. Do the work, then add photos of it and mark the job completed.</div><div data-workphotos="${esc(b.id)}"></div>`
    : b.status === "confirmed" && lastHour(b.scheduled_at) ? `<div class="muted small" style="margin-top:10px">Cancelling closed 1 hour before the start. Only Wasel can cancel now. Use Messages or contact support.</div>` : "";
  const fee = Number(b.platform_commission);
  return `
  <article class="card booking" data-id="${esc(b.id)}">
    <div class="top">
      <div>
        <h3>${esc(b.service?.name ?? "Service")}</h3>
        <div class="muted small">${esc(b.customer?.full_name || "Customer")}${b.customer?.phone ? " · " + esc(b.customer.phone) : ""} · ${cr && Number(cr.review_count) > 0 ? `<span class="cust-rating">★ ${esc(Number(cr.avg_rating).toFixed(1))} <span class="muted">(${esc(cr.review_count)})</span></span>` : `<span class="cust-rating muted">New customer, no ratings yet</span>`}</div>
      </div>
      ${pill(b.status === "pending" ? "review" : b.status, BOOKING_LABEL[b.status] ?? b.status)}
    </div>
    <dl>
      <div><dt>When</dt><dd>${esc(formatDateTime(b.scheduled_at))}</dd></div>
      <div><dt>Price</dt><dd>${money(b.service_price)} <span class="muted small">(you receive ${money(b.provider_payout)} after a ${money(fee)} fee)</span></dd></div>
      <div class="wide"><dt>Where</dt><dd>${esc(b.customer_address)}${b.customer_city ? ", " + esc(b.customer_city) : ""}${b.customer_zip_code ? " " + esc(b.customer_zip_code) : ""}${mi != null ? ` <span class="dist">· 📍 ${esc(mi.toFixed(1))} mi from you</span>` : ""}</dd></div>
      ${b.customer_notes ? `<div class="wide"><dt>Customer notes</dt><dd>${esc(b.customer_notes)}</dd></div>` : ""}
    </dl>
    ${payoutLine(b, pay, payoutOn)}
    ${rateCustomer(b, mine)}
    ${trip}
    ${chatBox({ ...b, customer: true })}
    ${actions.length ? `<div class="actions"><div class="btn-row">${actions.map(([to, label, cls]) => `<button class="btn btn-sm ${cls}" data-to="${to}">${label}</button>`).join("")}</div></div>` : ""}
  </article>`;
}

// ============================================================ services tab
const STATUS_OPTIONS = [["draft", "Draft (hidden)"], ["active", "Active (visible to customers)"], ["inactive", "Inactive (hidden)"]];

function serviceFields(s = {}) {
  const st = STATUS_OPTIONS.map(([v, l]) => `<option value="${v}" ${v === (s.status ?? "active") ? "selected" : ""}>${l}</option>`).join("");
  return `
    <div class="row3">
      <div class="field"><label>Price (USD)</label><input name="price" type="number" min="1" max="100000" step="0.01" required value="${esc(s.price ?? "")}"></div>
      <div class="field"><label>Duration (minutes)</label><input name="duration_minutes" type="number" min="5" step="5" required value="${esc(s.duration_minutes ?? 60)}"></div>
      <div class="field"><label>Visibility</label><select name="status">${st}</select></div>
    </div>`;
}

function readService(form) {
  return {
    price: Number(form.price.value),
    duration_minutes: parseInt(form.duration_minutes.value, 10),
    status: form.status.value,
  };
}

// the services Wasel offers that this provider has not chosen yet
function pickList(catalog, taken) {
  const free = catalog.filter((c) => !taken.has(c.id));
  if (!catalog.length) return `<div class="empty" style="padding:16px">Wasel has not added any services yet. Please check back soon.</div>`;
  if (!free.length) return `<div class="empty" style="padding:16px">You already offer every service on the list.</div>`;
  return CATEGORIES.map((cat) => {
    const items = free.filter((c) => c.category === cat.slug);
    if (!items.length) return "";
    return `<h3 class="small muted" style="margin:16px 0 8px">${esc(cat.icon)} ${esc(cat.label)}</h3>` + items.map((c) => `
      <form class="pick-form card" data-catalog="${esc(c.id)}" style="padding:12px;margin-bottom:8px">
        <div><strong>${esc(c.name)}</strong>${c.description ? `<div class="small muted">${esc(c.description)}</div>` : ""}</div>
        <div class="btn-row" style="align-items:flex-end;margin-top:8px">
          <div class="field" style="margin:0"><label class="small muted">Price (USD)</label><input name="price" type="number" min="1" max="100000" step="0.01" required value="${esc(c.suggested_price ?? "")}" ${c.suggested_price ? "" : 'placeholder="0.00"'} style="max-width:130px" aria-label="Price for ${esc(c.name)}"></div>
          <div class="field" style="margin:0"><label class="small muted">Duration (minutes)</label><input name="duration_minutes" type="number" min="5" step="5" required value="${esc(c.default_duration_minutes)}" style="max-width:120px" aria-label="Duration for ${esc(c.name)}"></div>
          <button class="btn btn-sm" type="submit">Offer this service</button>
        </div>
        <div class="pick-msg" hidden></div>
      </form>`).join("");
  }).join("");
}

async function tabServices(provider, body) {
  const [{ data, error }, { data: catalog }] = await Promise.all([
    sb.from("services").select("*, photos:service_photos(id, storage_path, sort_order), catalog:service_catalog(is_active)").eq("provider_id", provider.id).order("created_at", { ascending: false }),
    sb.from("service_catalog").select("id, name, description, category, suggested_price, default_duration_minutes").order("name"),
  ]);
  if (error) return (body.innerHTML = `<div class="alert alert-error">Could not load services: ${esc(friendlyMessage(error.message))}</div>`);
  const services = data ?? [];
  const approved = provider.status === "approved";

  body.innerHTML = `
    ${approved
      ? `<details class="add-box" id="add-box"><summary class="btn">+ Choose services to offer</summary>
           <p class="small muted" style="margin:12px 0 0">Wasel keeps the list of services. Pick the ones you do and set your own price.</p>
           <div id="pick-msg" hidden></div>
           <div id="pick-list">${pickList(catalog ?? [], new Set(services.map((x) => x.catalog_id)))}</div></details>`
      : `<div class="alert alert-warn">You can choose services once your application is approved.</div>`}
    <h2 class="section-title">Your services (${services.length})</h2>
    <div id="svc-msg" hidden></div>
    ${services.length ? services.map(serviceCard).join("") : `<div class="empty" style="margin-top:12px;padding:20px">You have not chosen any services yet.</div>`}`;

  try {
    const f = sessionStorage.getItem("svcFlash"); sessionStorage.removeItem("svcFlash");
    if (f) showMessage(document.getElementById("svc-msg"), f, "ok");
  } catch { /* ignore */ }

  document.getElementById("pick-list")?.addEventListener("submit", async (e) => {
    const form = e.target.closest(".pick-form");
    if (!form) return;
    e.preventDefault();
    const msg = form.querySelector(".pick-msg");
    const price = Number(form.price.value), dur = parseInt(form.duration_minutes.value, 10);
    if (!(price >= 1 && price <= 100000) || !(dur > 0)) return showMessage(msg, "Enter a price between $1 and $100,000 and a valid duration.");
    const btn = form.querySelector("button[type=submit]"); btn.disabled = true;
    const { error } = await sb.from("services").insert({ provider_id: provider.id, catalog_id: form.dataset.catalog, price, duration_minutes: dur, status: "active" });
    if (error) { btn.disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
    flashNext("Added. Customers can book it now. You can add photos below.");
    location.href = "provider.html?tab=services";
  });

  body.addEventListener("click", async (e) => {
    const btn = e.target.closest("[data-svc], [data-photo-act]");
    if (!btn) return;
    const card = btn.closest("[data-id]");
    const msg = document.getElementById("svc-msg");
    if (btn.dataset.svc === "edit") card.querySelector(".edit-form").hidden = !card.querySelector(".edit-form").hidden;
    if (btn.dataset.svc === "delete") {
      if (!confirm(waselT("Delete this service?"))) return;
      const paths = [...card.querySelectorAll(".photo")].map((el) => el.dataset.path);
      const { error } = await sb.from("services").delete().eq("id", card.dataset.id);
      if (error) {
        return showMessage(msg, error.code === "23503"
          ? "This service has bookings, so it can't be deleted. Set its visibility to Inactive instead."
          : error.message);
      }
      if (paths.length) await sb.storage.from(PHOTO_BUCKET).remove(paths); // don't leave orphan files behind
      location.reload();
    }

    // ----- photos
    const act = btn.dataset.photoAct;
    if (act) {
      const ph = btn.closest(".photo");
      const pmsg = card.querySelector(".photo-msg");
      if (act === "delete") {
        if (!confirm(waselT("Delete this photo?"))) return;
        const { error } = await sb.from("service_photos").delete().eq("id", ph.dataset.photo);
        if (error) return showMessage(pmsg, error.message);
        await sb.storage.from(PHOTO_BUCKET).remove([ph.dataset.path]);
        location.reload();
      }
      if (act === "cover") {
        const lowest = Math.min(...[...card.querySelectorAll(".photo")].map((el) => Number(el.dataset.order)));
        const { error } = await sb.from("service_photos").update({ sort_order: lowest - 1 }).eq("id", ph.dataset.photo);
        if (error) return showMessage(pmsg, error.message);
        location.reload();
      }
    }
  });

  // ----- upload photos (file picker)
  body.addEventListener("click", async (e) => {
    const pick = e.target.closest("[data-pick]");
    if (!pick) return;
    const row = pick.closest(".upload-row");
    if (pick.dataset.pick !== "camera") return row.querySelector("[data-files-input]")?.click();
    // the camera: a live preview that proves it works; if it does not, the person is told why and can pick a file or skip
    const note = pick.closest("[data-id]").querySelector(".photo-msg");
    const file = await photoFromCamera((t) => showMessage(note, t, "warn"));
    if (file) setInputFile(row.querySelector("[data-files-input]"), file);
  });
  body.addEventListener("change", async (e) => {
    const input = e.target.closest("[data-upload]");
    if (!input) return;
    const card = input.closest("[data-id]");
    const msg = card.querySelector(".photo-msg");
    const files = [...input.files];
    input.value = "";
    if (!files.length) return;

    const existing = [...card.querySelectorAll(".photo")];
    const room = MAX_PHOTOS - existing.length;
    if (files.length > room) {
      return showMessage(msg, room > 0
        ? `You can add ${room} more photo${room > 1 ? "s" : ""} (maximum ${MAX_PHOTOS} per service).`
        : `This service already has ${MAX_PHOTOS} photos. Delete one first.`);
    }

    input.disabled = true;
    let order = Math.max(-1, ...existing.map((el) => Number(el.dataset.order))) + 1;
    let uploaded = 0;
    const problems = [];
    for (const [i, file] of files.entries()) {
      showMessage(msg, `Uploading ${i + 1} of ${files.length}…`, "ok");
      try {
        const blob = await prepareImage(file);
        // the first folder MUST be your user id (the storage rules require it)
        const path = `${user.id}/${card.dataset.id}/${crypto.randomUUID()}.jpg`;
        const up = await sb.storage.from(PHOTO_BUCKET).upload(path, blob, { contentType: "image/jpeg", cacheControl: "31536000" });
        if (up.error) throw up.error;
        const ins = await sb.from("service_photos").insert({ service_id: card.dataset.id, storage_path: path, sort_order: order++ });
        if (ins.error) {
          await sb.storage.from(PHOTO_BUCKET).remove([path]);
          throw ins.error;
        }
        uploaded++;
      } catch (err) {
        problems.push(err.message ?? String(err));
      }
    }
    if (uploaded) {
      if (problems.length) sessionStorage.setItem("photoFlash", JSON.stringify({ id: card.dataset.id, text: `${uploaded} uploaded. ${problems.join(" ")}` }));
      location.reload();
    } else {
      input.disabled = false;
      showMessage(msg, problems.join(" "));
    }
  });

  // message left over from an upload that partly failed (the page reloaded to show the new photos)
  try {
    const flash = JSON.parse(sessionStorage.getItem("photoFlash") ?? "null");
    sessionStorage.removeItem("photoFlash");
    const box = flash && body.querySelector(`[data-id="${CSS.escape(flash.id)}"] .photo-msg`);
    if (box) showMessage(box, flash.text, "warn");
  } catch { /* ignore */ }

  body.addEventListener("submit", async (e) => {
    const pf = e.target.closest(".price-form");
    if (pf) {
      e.preventDefault();
      const card = pf.closest("[data-id]"), msg = pf.querySelector(".price-msg"), btn = pf.querySelector("button");
      const price = Number(pf.price.value);
      if (!(price >= 1 && price <= 100000)) return showMessage(msg, "The price must be between $1 and $100,000.");
      btn.disabled = true;
      const { data: rows, error } = await sb.from("services").update({ price }).eq("id", card.dataset.id).select("id, price");
      btn.disabled = false;
      if (error || !rows?.length) return showMessage(msg, friendlyMessage(error?.message ?? "Could not change the price."));
      const meta = card.querySelector(".meta");
      meta.textContent = meta.textContent.replace(/\$[\d,.]+/, money(rows[0].price));
      pf.price.value = Number(rows[0].price).toFixed(2);
      return showMessage(msg, `Price is now ${money(rows[0].price)}. Bookings that were already made keep their old price.`, "ok");
    }
    const form = e.target.closest(".edit-form");
    if (!form) return;
    e.preventDefault();
    const msg = form.querySelector(".edit-msg");
    const svc = readService(form);
    if (!(svc.price >= 1 && svc.price <= 100000) || !(svc.duration_minutes > 0)) return showMessage(msg, "Enter a price between $1 and $100,000 and a valid duration.");
    const id = form.closest("[data-id]").dataset.id;
    const { error } = await sb.from("services").update(svc).eq("id", id);
    if (error) return showMessage(msg, friendlyMessage(error.message));
    location.reload();
  });
}

function flashNext(text) { try { sessionStorage.setItem("svcFlash", text); } catch { /* ignore */ } }

function serviceCard(s) {
  const photos = sortPhotos(s.photos);
  const full = photos.length >= MAX_PHOTOS;
  return `
  <article class="card svc" data-id="${esc(s.id)}">
    <div class="top">
      <div><h3>${esc(s.name)}</h3>
        <div class="meta">${esc(categoryLabel(s.category))} · ${money(s.price)} · ${esc(s.duration_minutes)} min</div></div>
      ${s.catalog === null || s.catalog?.is_active === false ? pill("suspended", "Paused by Wasel") : pill(s.status, { draft: "Draft", active: "Active", inactive: "Inactive" }[s.status] ?? s.status)}
    </div>
    ${s.catalog === null || s.catalog?.is_active === false ? `<div class="alert alert-warn" style="margin-top:12px">Wasel has paused this service, so customers cannot see or book it for now. Your existing bookings are not affected.</div>` : ""}
    ${s.description ? `<p class="small" style="margin:12px 0 0;color:var(--text-2)">${esc(s.description)}</p>` : ""}
    <div class="photos">${photos.map((ph, i) => `
      <div class="photo" data-photo="${esc(ph.id)}" data-path="${esc(ph.storage_path)}" data-order="${esc(ph.sort_order)}">
        <img src="${esc(photoUrl(ph.storage_path))}" alt="Photo ${i + 1} of ${esc(s.name)}" loading="lazy">
        <div class="cap">${i === 0 ? `<span class="cover">Cover</span>` : `<button type="button" data-photo-act="cover">Make cover</button>`}
          <button type="button" class="del" data-photo-act="delete">Delete</button></div>
      </div>`).join("")}</div>
    <div class="upload-row">
      <span class="small muted">Photos (${photos.length}/${MAX_PHOTOS})</span>
      <button type="button" class="btn btn-sm btn-outline" data-pick="files" ${full ? "disabled" : ""}>Choose from files</button>
      <button type="button" class="btn btn-sm btn-outline" data-pick="camera" ${full ? "disabled" : ""}>Take a photo</button>
      <input type="file" data-upload data-files-input accept="image/*" multiple hidden ${full ? "disabled" : ""} aria-label="Add photos to ${esc(s.name)} from your files">
      <span class="hint" style="flex-basis:100%;margin:0">Photos are optional: use the camera, pick a file, or skip and add them later.</span>
    </div>
    <div class="photo-msg" hidden></div>
    <form class="price-form" style="margin-top:16px">
      <label class="small muted" for="price-${esc(s.id)}">Price (USD)</label>
      <div class="btn-row" style="align-items:center"><input id="price-${esc(s.id)}" name="price" type="number" min="1" max="100000" step="0.01" required value="${esc(Number(s.price).toFixed(2))}" style="max-width:140px">
        <button class="btn btn-sm" type="submit">Update price</button></div>
      <div class="price-msg" hidden></div>
    </form>
    <div class="btn-row" style="margin-top:16px">
      <button class="btn btn-sm btn-outline" data-svc="edit">Edit</button>
      <button class="btn btn-sm btn-danger" data-svc="delete">Remove</button>
    </div>
    <form class="edit-form" hidden style="margin-top:16px"><p class="small muted" style="margin-top:0">The name, description and category are set by Wasel. You can change your price, duration and visibility.</p>${serviceFields(s)}<div class="edit-msg" hidden></div>
      <button class="btn btn-sm" type="submit">Save changes</button></form>
  </article>`;
}

// ============================================================ profile tab
async function payoutCard(provider) {
  const box = document.getElementById("payout-box");
  const st = ((await sb.rpc("my_payout_status")).data ?? [])[0];
  const flash = params().get("connect");
  const msg = (t, k) => `<div class="alert alert-${k}" style="margin-bottom:12px">${esc(t)}</div>`;
  let html = "";
  if (!st?.connected) {
    html = `<p>Connect a bank account so Wasel can pay you when a job is completed and the customer has paid. Setup is done securely on Stripe's website and takes a few minutes.</p>
      <button class="btn" data-connect="start">Set up payouts</button>`;
  } else if (!st.payouts_enabled) {
    html = `${flash === "return" ? msg("Stripe is still reviewing your details. Press “Check status” in a moment.", "warn") : ""}
      <p>Your payout account is not finished yet.</p>
      <div class="btn-row"><button class="btn" data-connect="start">Continue setup</button> <button class="btn btn-outline" data-connect="refresh">Check status</button></div>`;
  } else {
    html = `<p>${pill("completed", "Active")} Payouts are on. Your share (after the ${esc(provider.commission_rate)}% platform fee) is sent when a job is completed and paid.</p>`;
  }
  box.innerHTML = html + `<div id="payout-msg" hidden></div>`;
  box.querySelectorAll("[data-connect]").forEach((b) => b.addEventListener("click", async () => {
    const m = document.getElementById("payout-msg"); b.disabled = true;
    try {
      if (b.dataset.connect === "refresh") {
        const out = await callFunction("connect-onboard", { refresh: true });
        if (out.enabled) return payoutCard(provider);
        b.disabled = false; return showMessage(m, "Not finished yet. Complete the steps on Stripe, then check again.");
      }
      const out = await callFunction("connect-onboard");
      if (new URL(out.url).origin !== "https://connect.stripe.com") throw new Error("Unexpected address from the payment service.");
      location.assign(out.url);
    } catch (err) { b.disabled = false; showMessage(m, err.message); }
  }));
  if (flash === "return" && st?.connected && !st.payouts_enabled) {
    callFunction("connect-onboard", { refresh: true }).then((o) => o.enabled && payoutCard(provider)).catch(() => {});
  }
}

async function planCard(provider) {
  const box = document.getElementById("plan-box");
  const st = ((await sb.rpc("my_subscription")).data ?? [])[0];
  const settings = await getSettings();
  const flash = params().get("pro");
  const msg = (t, k) => `<div class="alert alert-${k}" style="margin-bottom:12px">${esc(t)}</div>`;
  const until = st?.current_period_end ? new Date(st.current_period_end).toLocaleDateString(window.waselLocale, { timeZone: TZ, month: "short", day: "numeric", year: "numeric" }) : "";
  let html = "";
  if (st?.is_pro) {
    html = `${flash === "1" ? msg("Welcome to Wasel Pro!", "ok") : ""}
      <p>${pill("completed", "Wasel Pro")} Your platform fee is ${esc(st.commission_rate)}% and your services are listed first in search.${st.status === "past_due" ? " <strong>Your last card payment failed. Update your card to keep Pro.</strong>" : ""}${until ? ` Current period ends ${esc(until)}.` : ""}</p>
      <button class="btn btn-outline" data-plan="manage">Manage subscription</button>`;
  } else {
    html = `${flash === "1" ? msg("Thanks! Your plan is being activated. Refresh in a moment.", "warn") : flash === "cancelled" ? msg("No problem. You were not charged.", "warn") : ""}
      <p>You are on the <strong>Free</strong> plan: ${esc(st?.commission_rate ?? provider.commission_rate)}% platform fee per booking.</p>
      <p><strong>Wasel Pro</strong> is ${esc(dollars(settings.pro_price_cents))} per month: <strong>${esc(pct(settings.pro_fee_percent))}</strong> platform fee and your services are shown <strong>first</strong> in search. The new fee applies to bookings made after you upgrade. Cancel any time.</p>
      <div class="btn-row"><button class="btn" data-plan="upgrade">Upgrade to Pro</button>${st?.has_customer ? ' <button class="btn btn-outline" data-plan="manage">Billing</button>' : ""}</div>`;
  }
  box.innerHTML = html + `<div id="plan-msg" hidden></div>`;
  box.querySelectorAll("[data-plan]").forEach((b) => b.addEventListener("click", async () => {
    const m = document.getElementById("plan-msg"); b.disabled = true;
    try {
      const out = await callFunction("create-subscription", b.dataset.plan === "manage" ? { manage: true } : {});
      const host = new URL(out.url).origin;
      if (host !== "https://checkout.stripe.com" && host !== "https://billing.stripe.com") throw new Error("Unexpected address from the payment service.");
      location.assign(out.url);
    } catch (err) { b.disabled = false; showMessage(m, err.message); }
  }));
}

function tabProfile(provider, body) {
  const f = (name, label, extra = "") => `<div class="field"><label>${label}</label><input name="${name}" value="${esc(provider[name] ?? "")}" ${extra}></div>`;
  body.innerHTML = `
    <dl class="kv">
      <div><dt>Status</dt><dd>${esc(PROVIDER_LABEL[provider.status] ?? provider.status)}</dd></div>
      <div><dt>Platform fee</dt><dd>${esc(provider.commission_rate)}% per booking</dd></div>
      <div><dt>Rating</dt><dd>${provider.review_count ? `★ ${Number(provider.rating).toFixed(1)} (${provider.review_count})` : "No reviews yet"}</dd></div>
    </dl>
    <div class="panel" style="margin-bottom:16px"><h3 style="margin:0 0 4px">Documents</h3>
      <p class="hint" style="margin:0 0 12px">Your ID and a license or proof of insurance. Wasel admins use them to review your application.</p><div id="docs-box"></div></div>
    <div class="panel" id="plan-panel" style="margin-bottom:16px"><h3 style="margin:0 0 8px">Your plan</h3><div id="plan-box"><p class="muted loading">Loading…</p></div></div>
    <div class="panel" id="payout-panel" style="margin-bottom:16px"><h3 style="margin:0 0 8px">Get paid</h3><div id="payout-box"><p class="muted loading">Loading…</p></div></div>
    <div class="panel" style="margin-bottom:16px"><h3 style="margin:0 0 4px">Service areas</h3>
      <p class="hint" style="margin:0 0 12px">The cities and ZIP codes where you work. Customers only see you when they search one of these places.</p>
      <div id="areas-box"></div><div id="areas-msg" hidden></div>
      <button class="btn btn-sm" id="areas-save" type="button" style="margin-top:12px">Save service areas</button></div>
    ${provider.status === "approved" ? `<div class="panel" id="change-box" style="margin-bottom:16px"><p class="muted loading">Loading…</p></div>` : ""}
    <form id="profile-form" class="panel">
      ${provider.status === "approved" ? `<div class="alert alert-warn" style="margin-bottom:16px">Your profile is approved. <strong>Changes are sent to Wasel for approval</strong> and appear on your public page once an admin accepts them. You can attach supporting documents (for example a new license).</div>` : ""}
      ${f("business_name", "Business name", "required maxlength=120")}
      <div class="field"><label>About your business</label><textarea name="description" rows="4">${esc(provider.description ?? "")}</textarea></div>
      <div class="row2">${f("phone", "Phone", "type=tel")}${f("email", "Business email", "type=email")}</div>
      <div class="field"><label>I work as</label><div class="checks">
        <label><input type="radio" name="business_type" value="individual" ${provider.business_type === "individual" ? "checked" : ""}> An individual</label>
        <label><input type="radio" name="business_type" value="company" ${provider.business_type === "company" ? "checked" : ""}> A company</label></div></div>
      <div class="field"><label>Services you offer</label><div class="checks">${CATEGORIES.map((c) => `<label><input type="checkbox" name="cat" value="${esc(c.slug)}" ${(provider.categories ?? []).includes(c.slug) ? "checked" : ""}> ${esc(c.icon)} ${esc(c.label)}</label>`).join("")}</div></div>
      ${f("address", "Address")}
      <div class="row3">${f("city", "City")}${f("state", "State", "maxlength=2")}${f("zip_code", "ZIP code", "inputmode=numeric maxlength=10")}</div>
      <div class="row2">${f("years_experience", "Years of experience", "type=number min=0 max=60")}${f("website", "Website or social page", "type=url placeholder=https://")}</div>
      <div class="field"><label>Languages (separated by commas)</label><input name="languages" value="${esc((provider.languages ?? []).join(", "))}"></div>
      <div class="field"><label>License or insurance <span class="muted small">(private, only admins see it)</span></label><textarea name="license_info" rows="2" maxlength="300" id="license-field" disabled></textarea></div>
      <p class="hint">Your phone, email, address, business type, services, experience, languages and website are visible to customers on your public page.</p>
      ${provider.status === "approved" ? `<div class="field" style="margin-top:12px"><label>Why are you changing it? <span class="muted small">(optional, helps the admin)</span></label><textarea name="req_note" rows="2" maxlength="500"></textarea></div>
      <div class="field"><label>Supporting documents <span class="muted small">(optional)</span></label><div id="change-docs"></div></div>` : ""}
      <div id="pf-msg" hidden></div>
      <button class="btn" type="submit" style="margin-top:16px">${provider.status === "approved" ? "Send changes for approval" : "Save profile"}</button>
    </form>`;

  mountDocs(document.getElementById("docs-box"), { userId: user.id, providerId: provider.id, locked: provider.status === "approved" });
  const areaEditor = mountAreaEditor(document.getElementById("areas-box"), provider.areas ?? []);
  document.getElementById("areas-save").addEventListener("click", async (e) => {
    const msg = document.getElementById("areas-msg"), btn = e.currentTarget;
    if (!areaEditor.flush()) return showMessage(msg, "Fix the area you typed, or clear it, before saving.");
    btn.disabled = true;
    const { error } = await sb.rpc("set_service_areas", { p_areas: areaEditor.get() });
    btn.disabled = false;
    if (error) return showMessage(msg, error.message);
    showMessage(msg, areaEditor.get().length ? `Saved ${areaEditor.get().length} area${areaEditor.get().length > 1 ? "s" : ""}.` : "Saved. With no areas, customers cannot find you.", areaEditor.get().length ? "ok" : "warn");
  });

  if (provider.status === "approved") {
    Promise.all([payoutCard(provider), planCard(provider)]).then(() => {
      const t = location.hash === "#payout-box" ? "payout-panel" : location.hash === "#plan-box" ? "plan-panel" : null;
      if (t) { const el = document.getElementById(t); el?.scrollIntoView({ block: "start" }); el?.classList.add("flash"); }
    });
  }
  else document.getElementById("plan-box").innerHTML = `<p class="muted">Available once an admin approves your account.</p>`;
  if (provider.status !== "approved") document.getElementById("payout-box").innerHTML = `<p class="muted">Available once an admin approves your account.</p>`;

  sb.from("provider_private").select("license_info").eq("provider_id", provider.id).maybeSingle().then(({ data }) => {
    const box = document.getElementById("license-field");
    if (!box || !data) return;
    box.value = data.license_info ?? ""; box.disabled = false;
  });

  const approved = provider.status === "approved";
  const changeDocs = approved ? mountDocQueue(document.getElementById("change-docs"), [["other", "Supporting document"]], { max: 4, hint: "These are only shown to the Wasel admins." }) : null;
  if (approved) drawChangeBox(provider, changeDocs);

  document.getElementById("profile-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target, msg = document.getElementById("pf-msg");
    const v = (n) => form[n].value.trim() || null;
    const cats = [...form.querySelectorAll("[name=cat]:checked")].map((x) => x.value);
    const langs = form.languages.value.split(",").map((x) => x.trim()).filter(Boolean).slice(0, 8);
    const values = {
      business_name: form.business_name.value.trim(), description: v("description"), phone: v("phone"), email: v("email"),
      address: v("address"), city: v("city"), state: v("state"), zip_code: v("zip_code"),
      business_type: form.business_type.value || null, categories: cats.length ? cats : null,
      years_experience: form.years_experience.value === "" ? null : Number(form.years_experience.value),
      languages: langs.length ? langs : null, website: v("website"),
    };
    if (approved) return sendChange(provider, form, values, changeDocs, msg);
    const { error } = await sb.from("provider_profiles").update(values).eq("user_id", user.id);
    if (error) return showMessage(msg, error.message);
    if (!form.license_info.disabled) {
      const { error: e2 } = await sb.from("provider_private").update({ license_info: v("license_info") }).eq("provider_id", provider.id);
      if (e2) return showMessage(msg, e2.message);
    }
    showMessage(msg, "Saved.", "ok");
  });
}

// ---- change requests (approved providers): only the fields that really changed are sent
const FIELD_LABEL = { business_name: "Business name", description: "About your business", phone: "Phone", email: "Business email", address: "Address", city: "City", state: "State", zip_code: "ZIP code", business_type: "I work as", categories: "Services you offer", years_experience: "Years of experience", languages: "Languages", website: "Website", license_info: "License or insurance" };
const showVal = (k, val) => val == null || val === "" ? "(empty)" : Array.isArray(val) ? val.join(", ") : k === "business_type" ? (val === "company" ? "A company" : "An individual") : String(val);
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

async function sendChange(provider, form, values, queue, msg) {
  const btn = form.querySelector("button[type=submit]");
  const { data: pv } = await sb.from("provider_private").select("license_info").eq("provider_id", provider.id).maybeSingle();
  const all = { ...values };
  if (!form.license_info.disabled) all.license_info = form.license_info.value.trim() || null;
  const current = { ...provider, license_info: pv?.license_info ?? null };
  const changes = {};
  for (const [k, val] of Object.entries(all)) if (!same(val, current[k] ?? null) && !(k === "categories" && !val && !current[k]?.length)) changes[k] = val === null ? (k === "categories" || k === "languages" ? [] : "") : val;
  if (!Object.keys(changes).length) return showMessage(msg, "You have not changed anything yet.", "warn");
  btn.disabled = true;
  const uploaded = [];
  for (const it of queue.items()) {
    const r = await uploadDocWithId(user.id, provider.id, { kind: "other", file: it.file });
    if (r.error) { for (const u of uploaded) await removeDocById(u.id, u.path); btn.disabled = false; return showMessage(msg, r.error); }
    uploaded.push(r);
  }
  const { error } = await sb.rpc("submit_provider_change", { p_changes: changes, p_note: form.req_note.value.trim() || null, p_doc_ids: uploaded.map((u) => u.id) });
  btn.disabled = false;
  if (error) { for (const u of uploaded) await removeDocById(u.id, u.path); return showMessage(msg, friendlyMessage(error.message)); }
  queue.clear(); form.req_note.value = "";
  showMessage(msg, "Sent. Wasel will review your changes. Your public profile stays as it is until an admin approves them.", "ok");
  await drawChangeBox(provider, queue);
  document.getElementById("change-box")?.scrollIntoView({ behavior: "smooth", block: "start" });
}

async function drawChangeBox(provider) {
  const box = document.getElementById("change-box");
  if (!box) return;
  const { data, error } = await sb.from("provider_change_requests").select("id, status, changes, note, admin_note, created_at, reviewed_at").eq("provider_id", provider.id).order("created_at", { ascending: false }).limit(5);
  if (error) { box.innerHTML = `<div class="alert alert-error">${esc(friendlyMessage(error.message))}</div>`; return; }
  const rows = data ?? [];
  const when = (iso) => new Date(iso).toLocaleDateString(window.waselLocale, { timeZone: TZ, month: "short", day: "numeric" });
  const label = { pending: ["pending", "Waiting for Wasel"], approved: ["completed", "Approved"], rejected: ["declined", "Not approved"], cancelled: ["draft", "Cancelled"] };
  const item = (r) => `<div class="change-item" data-id="${esc(r.id)}" style="border-top:1px solid var(--line);padding:12px 0">
      <div>${pill(...label[r.status])} <span class="muted small">Sent ${esc(when(r.created_at))}${r.reviewed_at ? ` · decided ${esc(when(r.reviewed_at))}` : ""}</span></div>
      <ul class="small" style="margin:8px 0 0 18px">${Object.entries(r.changes).map(([k, val]) => `<li><strong>${esc(FIELD_LABEL[k] ?? k)}:</strong> ${esc(showVal(k, val))}</li>`).join("")}</ul>
      ${r.note ? `<div class="small muted" style="margin-top:6px">Your note: ${esc(r.note)}</div>` : ""}
      ${r.admin_note ? `<div class="small" style="margin-top:6px"><strong>Wasel:</strong> ${esc(r.admin_note)}</div>` : ""}
      ${r.status === "pending" ? `<button class="btn btn-sm btn-outline" data-cancel-change style="margin-top:8px">Cancel this request</button>` : ""}</div>`;
  box.innerHTML = `<h3 style="margin:0 0 4px">Profile change requests</h3>` + (rows.length
    ? `<p class="hint" style="margin:0 0 4px">Changes to an approved profile are reviewed by Wasel before they go live.</p>${rows.map(item).join("")}<div id="change-msg" hidden></div>`
    : `<p class="hint" style="margin:0">Nothing sent yet. Use the form below to ask for a change.</p>`);
  box.querySelectorAll("[data-cancel-change]").forEach((b) => b.addEventListener("click", async () => {
    b.disabled = true;
    const { error: e2 } = await sb.rpc("cancel_provider_change", { p_id: b.closest("[data-id]").dataset.id });
    if (e2) { b.disabled = false; return showMessage(document.getElementById("change-msg"), friendlyMessage(e2.message)); }
    await drawChangeBox(provider);
  }));
}

// ============================================================ start (kept at the END so every const above is ready)
if (!user) {
  location.replace("provider-login.html");
} else {
  await init(user);
}
