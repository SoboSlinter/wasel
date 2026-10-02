import { sb, renderChrome, loadPlaceSuggestions, esc, money, categoryLabel, categoryIcon, CATEGORIES, params, sortPhotos, photoUrl , friendlyMessage } from "./app.js";

await renderChrome();

const p = params();
const q = p.get("q") ?? "";
const place = (p.get("place") ?? p.get("zip") ?? "").trim().slice(0, 60);   // ?zip= still works for old links
const category = p.get("category") ?? "";
const PRICES = { "0-50": "Under $50", "50-100": "$50 – $100", "100-200": "$100 – $200", "200-": "$200 and up" };
const SORTS = { rating: "Highest rated", price_asc: "Price: low to high", price_desc: "Price: high to low", distance: "Nearest first", new: "Newest" };
const price = PRICES[p.get("price")] ? p.get("price") : "";
const sort = SORTS[p.get("sort")] ? p.get("sort") : "";

// fill the form with the current search
const form = document.getElementById("filters");
form.q.value = q;
form.place.value = place;
form.price.value = price;
form.sort.value = sort;
loadPlaceSuggestions();
form.category.innerHTML =
  `<option value="">All categories</option>` +
  CATEGORIES.map((c) => `<option value="${esc(c.slug)}" ${c.slug === category ? "selected" : ""}>${esc(c.label)}</option>`).join("");

const out = document.getElementById("results");

let query = sb
  .from("services")
  .select("id, name, description, category, price, duration_minutes, provider:provider_profiles!inner(id, business_name, city, zip_code, rating, review_count, is_pro), photos:service_photos(storage_path, sort_order)")
  .order("created_at", { ascending: false })
  .limit(100);

// remove characters that have a special meaning inside PostgREST filters
const cleanQ = q.replace(/[,()%*\\]/g, " ").trim();
if (cleanQ) query = query.or(`name.ilike.%${cleanQ}%,description.ilike.%${cleanQ}%`);
if (category) query = query.eq("category", category);
if (price) { const [lo, hi] = price.split("-"); if (lo) query = query.gte("price", Number(lo)); if (hi) query = query.lt("price", Number(hi)); }
if (sort === "price_asc") query = query.order("price", { ascending: true });
if (sort === "price_desc") query = query.order("price", { ascending: false });

// Only services whose provider says they work in that city / ZIP code.
let noneServe = false;
if (place) {
  const { data: ids, error: e } = await sb.rpc("services_in_area", { p_place: place });
  if (e) { out.innerHTML = `<div class="alert alert-error">Could not search that place: ${esc(friendlyMessage(e.message))}</div>`; throw e; }
  noneServe = !ids?.length;
  query = query.in("id", noneServe ? ["00000000-0000-0000-0000-000000000000"] : ids);
}

// active filters as removable chips
const without = (key) => { const u = new URLSearchParams(location.search); u.delete(key); return "services.html" + (u.toString() ? "?" + u : ""); };
const chips = [[q && `“${q}”`, "q"], [place && `📍 ${place}`, "place"], [category && categoryLabel(category), "category"], [price && PRICES[price], "price"], [sort && "Sort: " + SORTS[sort], "sort"]].filter(([l]) => l);
document.getElementById("active-filters").innerHTML = chips.length
  ? `<span class="muted small">Active filters:</span>` + chips.map(([l, k]) => `<a class="chip" href="${esc(without(k))}" title="Remove filter">${esc(l)} ✕</a>`).join("") + `<a class="link small" href="services.html">Clear all</a>` : "";

const { data, error } = await query;

if (error) {
  out.innerHTML = `<div class="alert alert-error">Could not load services: ${esc(friendlyMessage(error.message))}</div>`;
} else if (!data.length) {
  out.innerHTML = `<div class="empty"><strong>${noneServe ? `No providers serve “${esc(place)}” yet.` : "No services found."}</strong><br>
    <span class="small">Try a nearby city or ZIP code, or <a class="link" href="services.html">clear filters</a>.</span></div>`;
} else {
  if (place) out.insertAdjacentHTML("beforebegin", `<p class="muted" id="place-note">Providers serving <strong>${esc(place)}</strong></p>`);
  // approximate miles from the searched place to each provider's ZIP code
  const miles = new Map();
  if (place) {
    const { data: dist } = await sb.rpc("provider_distances", { p_place: place });
    for (const d of dist ?? []) miles.set(d.provider_id, Number(d.miles));
  }
  const milesOf = (s) => miles.get(s.provider.id);
  let sorted = [...data];
  if (sort === "distance") {
    if (!place) out.insertAdjacentHTML("beforebegin", `<p class="muted small" id="dist-note">Enter a city or ZIP code to sort by distance.</p>`);
    sorted.sort((a, b) => (milesOf(a) ?? 1e9) - (milesOf(b) ?? 1e9) || Number(b.provider.rating) - Number(a.provider.rating));
  } else if (sort === "rating") sorted.sort((a, b) => Number(b.provider.rating) - Number(a.provider.rating) || b.provider.review_count - a.provider.review_count);
  else if (!sort) sorted.sort((a, b) => Number(b.provider.is_pro) - Number(a.provider.is_pro)); // Recommended: Pro providers first (stable: newest first inside each group)
  document.getElementById("count").textContent = `${sorted.length} service${sorted.length === 1 ? "" : "s"} found`;
  out.innerHTML = `<div class="grid grid-3">${sorted.map((s) => card(s, milesOf(s))).join("")}</div>`;
  if (miles.size) out.insertAdjacentHTML("afterend", `<p class="hint" id="dist-hint">Distances are approximate (from ZIP code centers).</p>`);
  setupCompare(sorted, milesOf);
}

// ---- compare up to 3 services side by side
function setupCompare(list, milesOf) {
  const picked = new Set();
  const bar = document.createElement("div");
  bar.className = "cmp-bar"; bar.hidden = true;
  bar.innerHTML = `<span id="cmp-count"></span><button class="btn btn-sm" type="button" id="cmp-open">Compare</button><button class="btn btn-sm btn-outline" type="button" id="cmp-clear">Clear</button>`;
  document.body.appendChild(bar);
  const refresh = () => {
    bar.hidden = picked.size === 0;
    bar.querySelector("#cmp-count").textContent = `${picked.size} selected (up to 3)`;
    bar.querySelector("#cmp-open").disabled = picked.size < 2;
    out.querySelectorAll("[data-cmp]").forEach((b) => { const on = picked.has(b.dataset.cmp); b.classList.toggle("on", on); b.textContent = on ? "✓ Added" : "+ Compare"; });
  };
  out.addEventListener("click", (e) => {
    const b = e.target.closest("[data-cmp]");
    if (!b) return;
    e.preventDefault(); e.stopPropagation();
    const id = b.dataset.cmp;
    if (picked.has(id)) picked.delete(id); else if (picked.size < 3) picked.add(id);
    refresh();
  });
  bar.querySelector("#cmp-clear").onclick = () => { picked.clear(); refresh(); };
  bar.querySelector("#cmp-open").onclick = () => {
    const rows = list.filter((s) => picked.has(s.id));
    const dlg = document.createElement("dialog");
    dlg.className = "cmp-dialog";
    const cell = (f) => rows.map((s) => `<td>${f(s)}</td>`).join("");
    const best = (vals, low = true) => { const nums = vals.filter((v) => v != null); return nums.length > 1 ? (low ? Math.min(...nums) : Math.max(...nums)) : null; };
    const bestPrice = best(rows.map((s) => Number(s.price))), bestRate = best(rows.map((s) => (s.provider.review_count ? Number(s.provider.rating) : null)), false), bestDist = best(rows.map(milesOf));
    dlg.innerHTML = `<h2 style="font-size:1.125rem;margin:0 0 12px">Compare services</h2>
      <div style="overflow-x:auto"><table class="cmp-table"><thead><tr><th></th>${rows.map((s) => `<th><a class="link" href="service.html?id=${encodeURIComponent(s.id)}${place ? "&place=" + encodeURIComponent(place) : ""}">${esc(s.name)}</a></th>`).join("")}</tr></thead>
      <tbody>
        <tr><th>Provider</th>${cell((s) => esc(s.provider.business_name) + (s.provider.is_pro ? ' <span class="badge completed">Pro</span>' : ""))}</tr>
        <tr><th>Price</th>${cell((s) => `<strong class="${Number(s.price) === bestPrice ? "best" : ""}">${money(s.price)}</strong>`)}</tr>
        <tr><th>Average rating</th>${cell((s) => s.provider.review_count ? `<span class="${Number(s.provider.rating) === bestRate ? "best" : ""}">★ ${Number(s.provider.rating).toFixed(1)}</span> <span class="muted small">(${esc(s.provider.review_count)})</span>` : '<span class="muted">No reviews yet</span>')}</tr>
        <tr><th>Distance</th>${cell((s) => milesOf(s) != null ? `<span class="${milesOf(s) === bestDist ? "best" : ""}">${esc(milesOf(s).toFixed(1))} mi</span>` : '<span class="muted">' + (place ? "Unknown" : "Enter a city or ZIP") + "</span>")}</tr>
        <tr><th>Duration</th>${cell((s) => esc(s.duration_minutes) + " min")}</tr>
      </tbody></table></div>
      <div class="btn-row" style="margin-top:12px;justify-content:flex-end"><button class="btn btn-sm btn-outline" type="button" data-close>Close</button></div>`;
    document.body.appendChild(dlg);
    dlg.querySelector("[data-close]").onclick = () => { dlg.close(); dlg.remove(); };
    dlg.addEventListener("cancel", () => dlg.remove());
    dlg.showModal();
  };
  refresh();
}

function card(s, mi) {
  const pr = s.provider;
  const cover = sortPhotos(s.photos)[0];
  const rating = pr.review_count > 0 ? ` · ★ ${Number(pr.rating).toFixed(1)} (${pr.review_count})` : "";
  return `
    <a class="card" href="service.html?id=${encodeURIComponent(s.id)}${place ? "&place=" + encodeURIComponent(place) : ""}">
      <div class="thumb">${cover ? `<img src="${esc(photoUrl(cover.storage_path))}" alt="${esc(s.name)}" loading="lazy">` : esc(categoryIcon(s.category))}</div>
      <div class="eyebrow">${esc(categoryLabel(s.category))}</div>
      <h3>${esc(s.name)}</h3>
      <div class="muted small" style="margin-top:4px">${esc(pr.business_name)}${pr.is_pro ? ' <span class="badge completed">Pro</span>' : ""}${pr.city ? " · " + esc(pr.city) : ""}${mi != null ? ` · <span class="dist">📍 ${esc(mi.toFixed(1))} mi</span>` : ""}</div>
      ${s.description ? `<p class="desc">${esc(s.description)}</p>` : ""}
      <div class="foot">
        <span class="price">${money(s.price)}</span>
        <span class="muted small">${esc(s.duration_minutes)} min${rating}</span>
      </div>
      <span class="btn btn-sm view-btn">View details</span>
      <button type="button" class="btn btn-sm btn-outline cmp-btn" data-cmp="${esc(s.id)}">+ Compare</button>
    </a>`;
}
