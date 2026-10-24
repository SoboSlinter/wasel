// Shared code for every page: Supabase client, header/footer, small helpers.
import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";

export const configured =
  !SUPABASE_URL.startsWith("YOUR_") && !SUPABASE_KEY.startsWith("YOUR_");

export const sb = window.supabase.createClient(
  configured ? SUPABASE_URL : "http://localhost:54321",
  configured ? SUPABASE_KEY : "not-configured",
);

export const CATEGORIES = [
  { slug: "car_detailing", label: "Car Detailing", icon: "🚗" },
  { slug: "home_cleaning", label: "Home Cleaning", icon: "🏠" },
  { slug: "handyman", label: "Handyman", icon: "🔧" },
  { slug: "computer_repair", label: "Computer Repair", icon: "💻" },
];
export const categoryLabel = (slug) => CATEGORIES.find((c) => c.slug === slug)?.label ?? slug;

// ---------- helpers ----------

// ALWAYS pass database text through esc() before putting it in innerHTML (prevents XSS).
export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export const money = (n) => `$${Number(n).toFixed(2)}`;

// Fees and the Pro price are set by the admin; everybody reads them here. If the call fails we show the launch defaults.
export const DEFAULT_SETTINGS = { free_fee_percent: 10, pro_fee_percent: 5, pro_price_cents: 1900 };
let settingsCache;
export async function getSettings() {
  if (settingsCache) return settingsCache;
  try {
    const { data, error } = await sb.rpc("public_settings");
    if (!error && data?.[0]) return (settingsCache = data[0]);
  } catch { /* use the defaults */ }
  return DEFAULT_SETTINGS;
}
export const pct = (n) => `${Number(n)}%`;                                            // "12.00" -> "12%"
export const dollars = (cents) => `$${(Number(cents) / 100).toFixed(Number(cents) % 100 ? 2 : 0)}`;  // 1900 -> "$19", 1950 -> "$19.50"

export function formatDateTime(iso) {
  return new Date(iso).toLocaleString(window.waselLocale, {
    timeZone: "America/Chicago", weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  });
}

// Only allow redirects to pages inside this site.
export function safeNext(value, fallback = "index.html") {
  if (!value) return fallback;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value) || value.startsWith("//") || value.includes("\\")) return fallback;
  return value;
}

export const params = () => new URLSearchParams(location.search);

export function statusBadge(status) {
  const labels = {
    pending: "Waiting for provider", confirmed: "Confirmed", in_progress: "In progress",
    completed: "Completed", cancelled: "Cancelled", declined: "Declined",
  };
  return `<span class="badge ${esc(status)}">${esc(labels[status] ?? status)}</span>`;
}

// Browsers say "Failed to fetch" / "Load failed" when the network is down; say something a person can act on.
export function friendlyMessage(text) {
  const t = String(text ?? "");
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(t)) return "Could not reach Wasel. Check your internet connection and try again.";
  if (/row-level security/i.test(t)) return "You cannot do this right now. If your account was deactivated, please contact us.";
  return text;
}

export function showMessage(el, text, kind = "error") {
  el.textContent = kind === "error" ? friendlyMessage(text) : text;
  // keep the element's own classes (other code finds it by them); only swap the colour
  el.classList.remove("alert-error", "alert-ok", "alert-warn");
  el.classList.add("alert", `alert-${kind}`);
  el.hidden = !text;
}

// getSession() reads the saved login from the browser (no network call).
// Real security is enforced by the database (RLS), not by this value.
export async function getUser() {
  const { data } = await sb.auth.getSession();
  return data.session?.user ?? null;
}

export async function getRole(uid) {
  const { data } = await sb.from("profiles").select("role").eq("id", uid).maybeSingle();
  return data?.role ?? "customer";
}

// ---------- sidebar + top bar + footer ----------

// Small line icons (24x24, drawn with the text colour).
const ICONS = {
  home: '<path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10v10h13V10"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="3.5"/><path d="M8 3v4M16 3v4M3 10h18"/>',
  briefcase: '<rect x="3" y="7" width="18" height="13" rx="3.5"/><path d="M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7M3 13h18"/>',
  dashboard: '<rect x="3" y="3" width="7.5" height="7.5" rx="2.2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2.2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2.2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2.2"/>',
  wrench: '<path d="M14.5 6.5a4 4 0 0 0 4.9 4.9L21 9.8a6 6 0 0 1-8 7.7L6.5 21 3 17.5 9.8 11A6 6 0 0 1 17.5 3z"/>',
  settings: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2.2"/><circle cx="9" cy="17" r="2.2"/>',
  users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.6-3.6 3.2-5.5 6.5-5.5s5.9 1.9 6.5 5.5"/><circle cx="17.5" cy="9" r="2.5"/><path d="M17 14.6c2.4.2 4 1.8 4.5 4.4"/>',
  shield: '<path d="M12 3 4.5 6v5.5c0 4.5 3 7.7 7.5 9.5 4.5-1.8 7.5-5 7.5-9.5V6z"/><path d="m8.8 12 2.3 2.3 4.2-4.6"/>',
  alert: '<path d="M12 3.5 2.5 20h19z"/><path d="M12 10v4.5M12 17.4v.1"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="3.5"/><path d="m4 7.5 8 5.5 8-5.5"/>',
  layers: '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
  activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
  logout: '<path d="M9 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h3M16 8l4 4-4 4M20 12H9"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
};
export const icon = (name) =>
  `<svg class="ico" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${ICONS[name] ?? ""}</svg>`;

// Light / dark: follows the device until the person picks one with the sidebar button.
function currentTheme() {
  return document.documentElement.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
}
function setupThemeToggle() {
  const btn = document.getElementById("theme-toggle");
  if (!btn) return;
  const label = () => { btn.textContent = currentTheme() === "dark" ? "Light mode" : "Dark mode"; };
  label();
  btn.addEventListener("click", () => {
    const next = currentTheme() === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    document.documentElement.classList.toggle("glass-light", next !== "dark");
    try { localStorage.setItem("wasel-theme", next); } catch { /* private mode: still works for this visit */ }
    label();
  });
}

// Phone: the sidebar is a drawer opened by the menu button.
function setupSidebar() {
  const btn = document.querySelector(".menu-btn");
  const bar = document.getElementById("sidebar");
  if (!btn || !bar) return;
  const set = (open) => { document.body.classList.toggle("nav-open", open); btn.setAttribute("aria-expanded", String(open)); };
  btn.addEventListener("click", () => set(!document.body.classList.contains("nav-open")));
  document.querySelectorAll("[data-close-nav]").forEach((el) => el.addEventListener("click", () => set(false)));
  bar.addEventListener("click", (e) => { if (e.target.closest("a")) set(false); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") set(false); });
  matchMedia("(min-width: 901px)").addEventListener("change", (m) => { if (m.matches) set(false); });
}

// Provider and admin pages build their own section links (with counters); this moves them into the sidebar.
export function adoptTabs() {
  const nav = document.querySelector("main .dash > nav.tabs");
  const slot = document.getElementById("side-sub");
  if (!nav || !slot) return;
  slot.replaceChildren(nav);
  const group = slot.previousElementSibling;
  if (group?.matches("a.nav-item")) {
    const label = document.createElement("div");
    label.className = "side-label";
    label.textContent = group.textContent.trim();
    group.replaceWith(label);
  }
  document.body.classList.add("has-subnav");
}

export async function renderChrome() {
  const user = await getUser();
  let name = "";
  let role = "customer";
  let inactive = false;
  if (user) {
    const { data } = await sb.from("profiles").select("full_name, role, is_active, lang").eq("id", user.id).maybeSingle();
    inactive = data?.is_active === false;
    name = data?.full_name || user.email || "";
    role = data?.role ?? "customer";
    // Emails follow the language the person picked on the site. Only an explicit choice is saved (a browser guess is not).
    if (window.waselLangExplicit && data?.lang && data.lang !== window.waselLang) {
      sb.rpc("set_my_language", { p_lang: window.waselLang }).then(() => {}, () => {});
    }
  }

  const page = location.pathname.split("/").pop() || "index.html";
  const item = (href, label, ico) =>
    `<a class="nav-item" href="${href}"${href === page ? ' aria-current="page"' : ""}>${icon(ico)}<span>${label}</span></a>`;
  const home = role === "admin" && user ? "admin.html" : role === "provider" && user ? "provider.html" : "index.html";

  // Each kind of person gets their own menu.
  const items = !user
    ? [item("index.html", "Home", "home"), item("services.html", "Services", "search"), item("provider-signup.html", "Become a provider", "briefcase")]
    : role === "admin"
      ? [item("admin.html", "Admin", "dashboard")]
      : role === "provider"
        ? [item("provider.html", "Provider dashboard", "briefcase")]
        : [item("index.html", "Home", "home"), item("services.html", "Services", "search"), item("bookings.html", "My bookings", "calendar"), item("provider.html", "Become a provider", "briefcase")];
  const showLabel = !user || role === "customer";

  const shown = name.includes("@") ? name.split("@")[0] : name;
  const initial = esc((shown.trim()[0] || "W").toUpperCase());
  const roleLabel = role === "admin" ? "Admin" : role === "provider" ? "Provider" : "Customer";
  const hasSearch = page !== "index.html" && page !== "services.html";

  document.getElementById("site-header").innerHTML = `
    <div class="scrim" data-close-nav></div>
    <aside class="sidebar" id="sidebar" aria-label="Main menu">
      <div class="side-top">
        <a href="${home}" class="logo" aria-label="Wasel"><img class="logo-mark" src="img/logo-mark.png" alt="" width="24" height="31"><span>Wasel</span></a>
        <button type="button" class="icon-btn side-close" data-close-nav aria-label="Close menu">${icon("close")}</button>
      </div>
      ${showLabel ? `<div class="side-label">Menu</div>` : ""}
      <nav class="side-nav" aria-label="Main">${items.join("")}<div id="side-sub"></div></nav>
      <div class="side-bottom">
        ${user ? `<div class="side-user"><span class="avatar" aria-hidden="true">${initial}</span><div class="side-user-text"><strong>${esc(shown)}</strong><small>${roleLabel}</small></div></div>
        <button type="button" class="side-signout" id="signout">${icon("logout")}Sign out</button>` : ""}
        <div class="side-tools">
          <button type="button" class="theme-toggle" id="theme-toggle"></button>
        </div>
      </div>
    </aside>
    <header class="site-header topbar">
      <button type="button" class="icon-btn menu-btn" aria-label="Open menu" aria-expanded="false" aria-controls="sidebar">${icon("menu")}</button>
      <a href="${home}" class="logo topbar-logo" aria-label="Wasel"><img class="logo-mark" src="img/logo-mark.png" alt="" width="24" height="31"><span>Wasel</span></a>
      ${hasSearch ? `<form class="top-search" id="top-search" role="search">${icon("search")}<input id="top-q" type="search" placeholder="Search services" aria-label="Search services" maxlength="60" autocomplete="off"></form>` : ""}
      <button type="button" class="lang-pill" id="lang-toggle" data-lang-toggle data-no-i18n lang="${window.waselLang === "es" ? "en" : "es"}" title="${window.waselLang === "es" ? "Switch to English" : "Cambiar a español"}"><span aria-hidden="true">🌐</span> ${window.waselLang === "es" ? "English" : "Español"}</button>
      <nav class="nav">
        ${user
          ? `<span class="who-chip"><span class="avatar" aria-hidden="true">${initial}</span><span class="who">${esc(name)}</span></span>`
          : `<a href="login.html">Log in</a><a href="signup.html" class="btn btn-sm">Sign up</a>`}
      </nav>
    </header>
    ${user && document.body.hasAttribute("data-welcome") ? `<section class="welcome"><p class="welcome-hi">Hi ${esc(shown)},</p><p class="welcome-title"><span>Welcome back</span> <span aria-hidden="true">👋</span></p></section>` : ""}
    <div class="shell-notes" id="shell-notes"></div>`;
  document.getElementById("top-search")?.addEventListener("submit", (e) => {
    e.preventDefault();
    const q = document.getElementById("top-q").value.trim();
    location.href = q ? `services.html?q=${encodeURIComponent(q)}` : "services.html";
  });

  const notes = document.getElementById("shell-notes");
  if (inactive) {
    notes.insertAdjacentHTML("beforeend", `<div class="alert alert-error account-banner" role="alert">Your account is deactivated, so you cannot book, review or change bookings. <a class="link" href="contact.html">Contact us</a> if you think this is a mistake.</div>`);
  }

  document.getElementById("site-footer").innerHTML = `
    <footer class="site-footer"><div class="container">
      © ${new Date().getFullYear()} Wasel — find trusted local services.
      <span class="foot-links"><a href="about.html">About</a> · <a href="contact.html">Contact</a> · <a href="terms.html">Terms</a> · <a href="privacy.html">Privacy</a> · <a href="provider-login.html">Provider log in</a> · <a href="admin-login.html">Admin</a></span>
    </div></footer>`;
  // contact details the main admin keeps (shown in the footer; the Contact page lists them too)
  loadSiteContacts().then((rows) => {
    const el = document.querySelector(".site-footer .container");
    if (rows.length && el && !el.querySelector(".foot-contact")) el.insertAdjacentHTML("beforeend", `<div class="foot-contact">${rows.filter((c) => ["email", "phone", "whatsapp"].includes(c.kind)).map((c) => `<span>${esc(c.label)}: ${contactLink(c)}</span>`).join(" · ")}</div>`);
  });
  setupThemeToggle();
  setupSidebar();

  document.getElementById("signout")?.addEventListener("click", async () => {
    await sb.auth.signOut();
    location.href = "index.html";
  });

  if (!configured) {
    notes.insertAdjacentHTML("beforeend", `<div class="alert alert-warn">Supabase is not configured yet. Open <code>js/config.js</code> and add your project URL and publishable key.</div>`);
  }
  return user;
}

// ---------- service photos ----------

export const PHOTO_BUCKET = "service-photos";
export const MAX_PHOTOS = 5;

export const categoryIcon = (slug) => CATEGORIES.find((c) => c.slug === slug)?.icon ?? "🛠️";

// Photos of a service, cover photo first.
export const sortPhotos = (photos) => [...(photos ?? [])].sort((a, b) => a.sort_order - b.sort_order);

export const photoUrl = (path) => sb.storage.from(PHOTO_BUCKET).getPublicUrl(path).data.publicUrl;

// Shrinks a picture before upload (phone photos are often 5-10 MB). Always returns a JPEG blob.
export async function prepareImage(file, maxSide = 1600) {
  if (!file.type.startsWith("image/")) throw new Error(`"${file.name}" is not an image.`);
  let bitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    throw new Error(`"${file.name}" could not be read as a picture. Try a JPG or PNG.`);
  }
  const scale = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close?.();
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
  if (!blob) throw new Error(`"${file.name}" could not be processed.`);
  if (blob.size > 5 * 1024 * 1024) throw new Error(`"${file.name}" is still larger than 5 MB after shrinking.`);
  return blob;
}

// Call one of our Supabase Edge Functions as the signed-in user.
export async function callFunction(name, body = {}) {
  const { data: { session } } = await sb.auth.getSession();
  let res;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: SUPABASE_KEY, authorization: `Bearer ${session?.access_token}` },
      body: JSON.stringify(body),
    });
  } catch (e) { throw new Error(friendlyMessage(e.message)); }
  const out = await res.json().catch(() => ({}));
  if (res.status === 404 && !out.error) throw new Error("Online payments are not set up yet (the " + name + " function is not deployed).");
  if (!res.ok) throw new Error(out.error || "Something went wrong. Try again.");
  return out;
}

// Ask the server to send any waiting booking emails now (the scheduler does it too, so this is only for speed).
// Never throws and never waits long: a failed email must not break a booking.
export function kickEmails() {
  return Promise.race([callFunction("send-emails").catch(() => {}), new Promise((r) => setTimeout(r, 1500))]);
}

// Fill the "City or ZIP code" box with places providers really serve.
export async function loadPlaceSuggestions() {
  const list = document.getElementById("place-suggestions");
  if (!list) return;
  const { data } = await sb.from("provider_service_areas").select("label").limit(500);
  const seen = new Set();
  const labels = (data ?? []).map((r) => r.label).filter((l) => !seen.has(l.toLowerCase()) && seen.add(l.toLowerCase()));
  labels.sort((x, y) => x.localeCompare(y));
  list.innerHTML = labels.map((l) => `<option value="${esc(l)}"></option>`).join("");
}

// Last safety net: if a page crashes while loading (network drop, unexpected error) show a banner
// instead of leaving a blank screen or a "Loading…" that never ends.
function crashBanner() {
  if (document.getElementById("crash-banner")) return;
  const d = document.createElement("div");
  d.id = "crash-banner"; d.className = "alert alert-error crash-banner"; d.setAttribute("role", "alert");
  d.innerHTML = `Something went wrong while loading this page. <a href="" class="link">Reload</a>`;
  document.body.prepend(d);
  document.querySelectorAll(".loading").forEach((el) => { el.classList.remove("loading"); el.textContent = "Could not load."; });
}
window.addEventListener("unhandledrejection", crashBanner);
window.addEventListener("error", (e) => { if (e.error) crashBanner(); }); // a script that throws while the page loads
window.addEventListener("offline", () => document.body.classList.add("is-offline"));
window.addEventListener("online", () => document.body.classList.remove("is-offline"));


// ---------- contact details of the team (edited by the main admin) ----------
export async function loadSiteContacts() {
  try {
    const { data, error } = await sb.from("site_contacts").select("id, kind, label, value, sort_order").order("sort_order").order("created_at");
    return error ? [] : (data ?? []);
  } catch { return []; }
}
// one safe link or text for a contact row (only mailto:, tel: and https: links are ever created)
export function contactLink(c) {
  const v = esc(c.value);
  if (c.kind === "email") return `<a class="link" href="mailto:${esc(encodeURI(c.value))}">${v}</a>`;
  if (c.kind === "phone" || c.kind === "whatsapp") return `<a class="link" href="tel:${esc(String(c.value).replace(/[^0-9+]/g, ""))}">${v}</a>`;
  if ((c.kind === "website" || c.kind === "social") && /^https?:\/\//i.test(c.value)) return `<a class="link" href="${esc(c.value)}" rel="noopener noreferrer" target="_blank">${v}</a>`;
  return v;
}


// ---------- "it worked" / "sorry, it did not work" messages that stay long enough to read ----------
// ok: shows a success card and, when `next` is true, waits long enough to read it (about 3 words a second)
// before resolving. A failure card never closes by itself: the person closes it. Resolves when it closes.
export function showOutcome({ ok, title, text = "", wait = true, continueLabel = "Continue", closeLabel = "Close" }) {
  return new Promise((resolve) => {
    document.querySelector(".outcome-dialog")?.remove();
    const words = `${title} ${text}`.trim().split(/\s+/).length;
    let left = ok && wait ? Math.max(6, Math.ceil(words / 3) + 3) : 0;
    const dlg = document.createElement("dialog");
    dlg.className = `outcome-dialog ${ok ? "is-ok" : "is-bad"}`;
    dlg.setAttribute("role", ok ? "status" : "alertdialog");
    dlg.setAttribute("aria-labelledby", "outcome-title");
    dlg.innerHTML = `<div class="outcome-icon" aria-hidden="true">${ok ? "✓" : "!"}</div>
      <h2 id="outcome-title">${esc(title)}</h2>${text ? `<p>${esc(text)}</p>` : ""}
      ${left ? `<p class="small muted" data-count></p>` : ""}
      <div class="btn-row" style="justify-content:center"><button type="button" class="btn" data-go>${esc(ok && wait ? continueLabel : closeLabel)}</button></div>`;
    document.body.appendChild(dlg);
    let timer = null;
    const done = () => { clearInterval(timer); dlg.close(); dlg.remove(); resolve(); };
    dlg.querySelector("[data-go]").onclick = done;
    dlg.addEventListener("cancel", (e) => { e.preventDefault(); done(); });
    if (left) {
      const c = dlg.querySelector("[data-count]");
      const tick = () => { c.textContent = `Continuing in ${left} second${left === 1 ? "" : "s"}…`; };
      tick();
      timer = setInterval(() => { left -= 1; if (left <= 0) return done(); tick(); }, 1000);
      // someone who is still reading can stop the countdown by touching the card
      dlg.addEventListener("pointerdown", () => { clearInterval(timer); c.textContent = "Take your time. Press Continue when you are ready."; }, { once: true });
    }
    dlg.showModal();
    dlg.querySelector("[data-go]").focus();
  });
}
