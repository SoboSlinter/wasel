import { sb, renderChrome, esc, money, categoryLabel, categoryIcon, params, showMessage, friendlyMessage, sortPhotos, photoUrl, kickEmails } from "./app.js";

const user = await renderChrome();
const out = document.getElementById("service");
const id = params().get("id");

const { data: s, error: loadErr } = id
  ? await sb
      .from("services")
      .select("id, name, description, category, price, duration_minutes, provider:provider_profiles!inner(id, business_name, description, city, zip_code, rating, review_count, business_type, categories, years_experience, languages, website, is_pro), photos:service_photos(storage_path, sort_order)")
      .eq("id", id)
      .maybeSingle()
  : { data: null };

if (loadErr) {
  out.innerHTML = `<div class="empty"><h1 style="font-size:1.5rem">Could not load this service</h1>
    <p>${esc(friendlyMessage(loadErr.message))}</p>
    <a class="link" href="">Try again</a></div>`;
} else if (!s) {
  out.innerHTML = `<div class="empty"><h1 style="font-size:1.5rem">Service not found</h1>
    <p>It may have been removed or is not available right now.</p>
    <a class="link" href="services.html">Browse services</a></div>`;
} else {
  document.title = `${s.name} — Wasel`;
  const pr = s.provider;
  const { data: areaRows } = await sb.from("provider_service_areas").select("kind, label").eq("provider_id", pr.id);
  const areas = (areaRows ?? []).sort((a, b) => (a.kind === b.kind ? a.label.localeCompare(b.label) : a.kind === "city" ? -1 : 1));
  const photos = sortPhotos(s.photos);
  const placeQ = (params().get("place") ?? "").trim().slice(0, 60);
  let miles = null;
  if (placeQ) {
    const { data: dist } = await sb.rpc("provider_distances", { p_place: placeQ });
    const m = (dist ?? []).find((d) => d.provider_id === pr.id);
    if (m) miles = Number(m.miles);
  }
  const next = encodeURIComponent(`service.html?id=${s.id}`);
  out.innerHTML = `
    <a class="link small" href="services.html">← All services</a>
    <div class="gallery">
      <div class="main" id="main-photo">${photos.length ? `<img src="${esc(photoUrl(photos[0].storage_path))}" alt="${esc(s.name)}">` : esc(categoryIcon(s.category))}</div>
      ${photos.length > 1 ? `<div class="strip">${photos.map((ph, i) => `<button type="button" class="${i === 0 ? "on" : ""}" data-src="${esc(photoUrl(ph.storage_path))}" aria-label="Photo ${i + 1}"><img src="${esc(photoUrl(ph.storage_path))}" alt=""></button>`).join("")}</div>` : ""}
    </div>
    <div class="eyebrow" style="margin-top:24px">${esc(categoryLabel(s.category))}</div>
    <h1 style="margin-top:4px;font-size:1.875rem">${esc(s.name)}</h1>
    <p class="muted" style="margin:8px 0 0">by <strong style="color:var(--text)">${esc(pr.business_name)}</strong>${pr.city ? ` · ${esc(pr.city)}, TX` : ""}${miles != null ? ` · <span class="dist">📍 ${esc(miles.toFixed(1))} mi from ${esc(placeQ)}</span>` : ""}${pr.review_count > 0 ? ` · ★ ${Number(pr.rating).toFixed(1)} (${pr.review_count} review${pr.review_count === 1 ? "" : "s"})` : ""}</p>
    ${s.description ? `<p class="pre" style="margin-top:24px">${esc(s.description)}</p>` : ""}

    <div class="panel" style="display:flex;justify-content:space-between;align-items:center">
      <div><div class="price-big">${money(s.price)}</div><div class="muted small">about ${esc(s.duration_minutes)} minutes</div></div>
    </div>

    ${areas.length ? `<div class="areas-line"><span class="muted small">Serves:</span>${areas.map((a) => `<span class="chip">${esc(a.label)}</span>`).join("")}</div>` : ""}

    ${user ? bookingForm() : `
      <div class="panel soft">
        <strong>Log in to book this service</strong>
        <div style="margin-top:12px;display:flex;gap:12px;justify-content:center">
          <a class="btn" href="login.html?next=${next}">Log in</a>
          <a class="btn btn-outline" href="signup.html?next=${next}">Sign up</a>
        </div>
      </div>`}

    ${pr.description ? `<h2 style="margin-top:40px;font-size:1.125rem">About ${esc(pr.business_name)}</h2><p class="pre">${esc(pr.description)}</p>` : ""}
    ${providerFacts(pr)}
    <h2 style="margin-top:40px;font-size:1.125rem">Reviews${pr.review_count > 0 ? ` (${esc(pr.review_count)})` : ""}</h2>
    <div id="reviews" class="rev-list"><p class="muted small loading">Loading reviews…</p></div>`;
  loadReviews(pr.id, pr.review_count);

  async function loadReviews(providerId, count) {
    const box = document.getElementById("reviews");
    const { data, error } = await sb.rpc("provider_reviews", { p_provider_id: providerId, p_limit: 10 });
    if (error) return (box.innerHTML = `<p class="muted small">Reviews could not be loaded.</p>`);
    if (!data?.length) return (box.innerHTML = `<p class="muted small">No reviews yet. Reviews come from customers after a completed job.</p>`);
    box.innerHTML = data.map((r) => `<div class="rev"><span class="stars" aria-label="${esc(r.rating)} out of 5 stars">${"★".repeat(r.rating)}${"☆".repeat(5 - r.rating)}</span>
      <span class="muted small"> ${esc(r.reviewer)} · ${esc(new Date(r.created_at).toLocaleDateString(window.waselLocale, { month: "short", day: "numeric", year: "numeric" }))}</span>${r.comment ? `<p>${esc(r.comment)}</p>` : ""}</div>`).join("") +
      (count > data.length ? `<p class="muted small">Showing the latest ${data.length} of ${esc(count)}.</p>` : "");
  }

  function providerFacts(p) {
    const rows = [];
    if (p.business_type) rows.push(["Works as", p.business_type === "company" ? "A company" : "An individual"]);
    if (p.years_experience != null) rows.push(["Experience", `${p.years_experience} year${p.years_experience === 1 ? "" : "s"}`]);
    if (p.languages?.length) rows.push(["Languages", p.languages.map(esc).join(", ")]);
    if (p.website && /^https?:\/\//i.test(p.website)) rows.push(["Website", `<a class="link" href="${esc(p.website)}" target="_blank" rel="noopener noreferrer nofollow">${esc(p.website.replace(/^https?:\/\//i, ""))}</a>`]);
    if (!rows.length && !p.categories?.length) return "";
    return `<dl class="kv" style="margin-top:16px">${rows.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${k === "Languages" || k === "Website" ? v : esc(v)}</dd></div>`).join("")}</dl>` +
      (p.categories?.length ? `<div>${p.categories.map((c) => `<span class="tag">${esc(categoryLabel(c))}</span>`).join("")}</div>` : "");
  }

  // clicking a small picture shows it big
  document.querySelector(".gallery .strip")?.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-src]");
    if (!b) return;
    document.querySelector("#main-photo img").src = b.dataset.src;
    document.querySelectorAll(".gallery .strip button").forEach((x) => x.classList.toggle("on", x === b));
  });

  if (user) wireBookingForm(s.id, user.id, s.price);
}

function bookingForm() {
  return `
    <form id="booking" class="panel">
      <h2>Request a booking</h2>
      <div class="field"><label for="when">When?</label><input id="when" type="datetime-local" required></div>
      <div class="field"><label for="address">Service address</label><input id="address" required autocomplete="street-address"></div>
      <div class="row2">
        <div class="field"><label for="city">City</label><input id="city" autocomplete="address-level2"></div>
        <div class="field"><label for="zip">ZIP code</label><input id="zip" inputmode="numeric" maxlength="10" autocomplete="postal-code"></div>
      </div>
      <div class="field"><label for="notes">Notes for the provider (optional)</label><textarea id="notes" rows="3"></textarea></div>
      <div id="booking-msg" hidden></div>
      <button class="btn btn-block" type="submit" style="margin-top:16px">Send booking request</button>
      <p class="hint">The provider must confirm your request. You pay by card after the provider confirms your request.</p>
    </form>`;
}

function wireBookingForm(serviceId, userId, shownPrice) {
  const form = document.getElementById("booking");
  const msg = document.getElementById("booking-msg");

  // earliest selectable time = 1 hour from now, in the visitor's own time zone
  const d = new Date(Date.now() + 3600e3);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  form.when.min = d.toISOString().slice(0, 16);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    showMessage(msg, "");
    const date = new Date(form.when.value);
    if (Number.isNaN(date.getTime())) return showMessage(msg, "Please choose a date and time.");

    const btn = form.querySelector("button[type=submit]");
    btn.disabled = true;
    btn.textContent = "Sending…";

    // The database sets price, commission, provider and status — we only send what the customer decides.
    const { error } = await sb.from("bookings").insert({
      customer_id: userId,
      service_id: serviceId,
      quoted_price: shownPrice, // the price on screen: the database refuses the booking if the provider changed it meanwhile
      scheduled_at: date.toISOString(),
      customer_address: form.address.value.trim(),
      customer_city: form.city.value.trim() || null,
      customer_zip_code: form.zip.value.trim() || null,
      customer_notes: form.notes.value.trim() || null,
    });

    if (error) {
      btn.disabled = false;
      btn.textContent = "Send booking request";
      const changed = /price changed to \$(\d+(?:\.\d+)?)/.exec(error.message);
      if (changed) { shownPrice = Number(changed[1]); const big = document.querySelector(".price-big"); if (big) big.textContent = money(shownPrice); }
      return showMessage(msg, friendlyMessage(error.message));
    }
    await kickEmails();
    location.href = "bookings.html?booked=1";
  });
}
