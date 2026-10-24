import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";
import { chatBox, mountChats, mountWorkPhotos, lastHour } from "./serviceday.js";
import { sb, renderChrome, esc, money, formatDateTime, statusBadge, params, showMessage, callFunction, kickEmails , friendlyMessage } from "./app.js";

const user = await renderChrome();

if (!user) {
  // not signed in: go to login and come back here afterwards
  location.replace("login.html?next=" + encodeURIComponent("bookings.html"));
} else {
  await init(user);
}

async function init(user) {

  const TABS = [
    { key: "upcoming", label: "Upcoming", statuses: ["pending", "confirmed", "in_progress"] },
    { key: "completed", label: "Completed", statuses: ["completed"] },
    { key: "cancelled", label: "Cancelled", statuses: ["cancelled", "declined"] },
  ];

  const p = params();
  const active = TABS.find((t) => t.key === p.get("tab")) ?? TABS[0];
  document.getElementById("booked").hidden = !p.get("booked");
  document.getElementById("paid").hidden = !p.get("paid");
  document.getElementById("pay-cancelled").hidden = !p.get("pay_cancelled");

  const { data, error } = await sb
    .from("bookings")
    .select("id, scheduled_at, status, service_price, customer_address, customer_city, customer_notes, completed_at, confirmed_at, started_at, arrived_at, problem_status, service:services(id, name), provider:provider_profiles(id, business_name, phone), review:reviews(id, rating, comment), payment:payments(status, refund_status)")
    .eq("customer_id", user.id)
    .order("scheduled_at", { ascending: false });

  const rows = data ?? [];
  // my average rating from providers (shown only when at least one provider rated me)
  const { data: myr } = await sb.rpc("my_customer_rating");
  if (myr?.[0] && Number(myr[0].review_count) > 0) {
    document.getElementById("tabs").insertAdjacentHTML("beforebegin", `<p class="muted small" id="my-rating">Your rating from providers: <strong>★ ${esc(Number(myr[0].avg_rating).toFixed(1))}</strong> (${esc(myr[0].review_count)})</p>`);
  }
  const inTab = (t) => rows.filter((r) => t.statuses.includes(r.status));

  document.getElementById("tabs").innerHTML = TABS.map(
    (t) => `<a class="tab ${t.key === active.key ? "active" : ""}" href="bookings.html?tab=${t.key}">${esc(t.label)} (${inTab(t).length})</a>`,
  ).join("");

  const list = document.getElementById("list");
  const shown = inTab(active);
  if (active.key === "upcoming") shown.reverse(); // soonest first

  if (error) {
    list.innerHTML = `<div class="alert alert-error">Could not load bookings: ${esc(friendlyMessage(error.message))}</div>`;
  } else if (!shown.length) {
    list.innerHTML = `<div class="empty"><strong>Nothing here yet.</strong><br><a class="link small" href="services.html">Browse services</a></div>`;
  } else {
    list.innerHTML = shown.map(card).join("");
    mountChats(list, user.id, "Provider");
    list.querySelectorAll("[data-workphotos]").forEach((el) => mountWorkPhotos(el, { userId: user.id, bookingId: el.dataset.workphotos }));
  }

  function card(b) {
    const review = Array.isArray(b.review) ? b.review[0] : b.review;
    const showPhone = ["confirmed", "in_progress", "completed"].includes(b.status) && b.provider?.phone;
    const payment = Array.isArray(b.payment) ? b.payment[0] : b.payment;
    const isPaid = payment?.status === "paid";
    const refunded = payment?.status === "refunded";
    const refundDue = payment?.status === "paid" && ["cancelled", "declined"].includes(b.status);
    const canPay = ["confirmed", "in_progress", "completed"].includes(b.status) && !isPaid && Number(b.service_price) > 0;
    const canCancel = (b.status === "pending" || b.status === "confirmed") && !lastHour(b.scheduled_at);
    const canReview = b.status === "completed" && !review;
    const awaiting = b.status === "completed" && !b.confirmed_at && b.problem_status !== "open";
    const problemOpen = b.status === "completed" && b.problem_status === "open";
    const autoDate = b.completed_at ? new Date(new Date(b.completed_at).getTime() + 72 * 3600e3).toLocaleDateString(window.waselLocale, { month: "short", day: "numeric" }) : "";
    return `
    <article class="card booking" data-id="${esc(b.id)}" id="b-${esc(b.id)}">
      <div class="top">
        <div>
          <h3>${b.service ? `<a href="service.html?id=${encodeURIComponent(b.service.id)}">${esc(b.service.name)}</a>` : "Service"}</h3>
          <div class="muted small">${esc(b.provider?.business_name ?? "Provider")}</div>
        </div>
        <div>${statusBadge(b.status)}${isPaid && !refundDue ? ' <span class="badge completed">Paid</span>' : ""}${refunded ? ' <span class="badge completed">Refunded</span>' : ""}${refundDue ? ' <span class="badge pending">Refund pending</span>' : ""}</div>
      </div>
      <dl>
        <div><dt>When</dt><dd>${esc(formatDateTime(b.scheduled_at))}</dd></div>
        <div><dt>Price</dt><dd>${money(b.service_price)}</dd></div>
        <div class="wide"><dt>Where</dt><dd>${esc(b.customer_address)}${b.customer_city ? ", " + esc(b.customer_city) : ""}</dd></div>
        ${b.customer_notes ? `<div class="wide"><dt>Your notes</dt><dd>${esc(b.customer_notes)}</dd></div>` : ""}
        ${showPhone ? `<div><dt>Provider phone</dt><dd>${esc(b.provider.phone)}</dd></div>` : ""}
        ${review ? `<div class="wide"><dt>Your review</dt><dd><span class="stars" aria-label="${review.rating} out of 5 stars">${"★".repeat(review.rating)}${"☆".repeat(5 - review.rating)}</span>${review.comment ? `<div class="small" style="white-space:pre-wrap">${esc(review.comment)}</div>` : ""}</dd></div>` : ""}
      </dl>
      ${(b.status === "confirmed" || b.status === "pending") && lastHour(b.scheduled_at) ? `<div class="alert alert-warn" style="margin-top:10px">Your service starts within the hour. Cancelling is closed now. If you really need to cancel, message the provider or contact Wasel.</div>` : ""}
      ${b.status === "in_progress" ? `<div class="alert alert-ok" style="margin-top:10px">${b.arrived_at ? "🏠 Your provider arrived at your address and is working." : "🚗 Your provider started and is on the way."}</div>` : ""}
      ${["in_progress", "completed"].includes(b.status) ? `<div data-workphotos="${esc(b.id)}"></div>` : ""}
      ${chatBox(b)}
      ${awaiting ? `<div class="alert alert-warn confirm-box"><strong>Is the job done?</strong> ${esc(b.provider?.business_name ?? "The provider")} marked it as completed. Confirm it, or report a problem. If you do nothing it is confirmed automatically on ${esc(autoDate)} and the provider is paid.
        <div class="btns"><button class="btn btn-sm" data-action="confirm">Yes, the job is done</button> <button class="btn btn-sm btn-outline" data-action="show-problem">Report a problem</button></div>
        <form data-problem hidden><label for="pb-${esc(b.id)}">What went wrong?</label><textarea id="pb-${esc(b.id)}" name="note" rows="3" minlength="5" maxlength="1000" required placeholder="Tell us what was not done properly"></textarea>
          <div class="btns"><button class="btn btn-sm" type="submit">Send report</button> <button class="btn btn-sm btn-outline" type="button" data-action="hide-problem">Cancel</button></div></form></div>` : ""}
      ${problemOpen ? `<div class="alert alert-warn confirm-box"><strong>Problem reported.</strong> Wasel support is reviewing it. The provider is not paid until then.</div>` : ""}
      ${b.status === "completed" && b.confirmed_at ? `<div class="muted small" style="margin-top:12px">✓ You confirmed this job.</div>` : ""}
      ${canCancel || canReview || canPay || refundDue ? `
      <div class="actions">
        ${canPay ? `<button class="btn btn-sm" data-action="pay">Pay ${esc(money(b.service_price))}</button>` : ""}
        ${refundDue ? `<button class="btn btn-sm" data-action="refund">Get my refund</button>
        <div class="muted small">Your payment of ${esc(money(b.service_price))} is being returned to your card (it can take 5–10 business days to show up).</div>` : ""}
        ${canCancel ? `<button class="btn btn-sm btn-outline" data-action="cancel">Cancel booking</button>` : ""}
        ${canReview ? `
          <button class="btn btn-sm btn-outline" data-action="show-review">★ Rate this job</button>
          <form data-review hidden>
            <fieldset class="rate"><legend>Your rating</legend>
              <div class="star-input">${[5, 4, 3, 2, 1].map((n) => `<input type="radio" name="rating" id="r${n}-${esc(b.id)}" value="${n}" required><label for="r${n}-${esc(b.id)}" title="${n} star${n > 1 ? "s" : ""}"><span class="sr">${n} star${n > 1 ? "s" : ""}</span>★</label>`).join("")}</div>
            </fieldset>
            <label for="rc-${esc(b.id)}">Comment (optional)</label>
            <textarea id="rc-${esc(b.id)}" name="comment" rows="3" maxlength="1000" placeholder="How was it?"></textarea>
            <div class="btns"><button class="btn btn-sm" type="submit">Submit review</button>
              <button class="btn btn-sm btn-outline" type="button" data-action="hide-review">Not now</button></div>
          </form>` : ""}
        <div class="action-msg" hidden></div>
      </div>` : ""}
    </article>`;
  }

  // One click handler for every card (event delegation)
  list.addEventListener("click", async (e) => {
    const btn = e.target.closest("[data-action]");
    if (!btn) return;
    const cardEl = btn.closest("[data-id]");
    const id = cardEl.dataset.id;
    const msg = cardEl.querySelector(".action-msg");
    const action = btn.dataset.action;

    if (action === "show-review") { btn.hidden = true; cardEl.querySelector("[data-review]").hidden = false; }
    if (action === "hide-review") { cardEl.querySelector("[data-review]").hidden = true; cardEl.querySelector('[data-action="show-review"]').hidden = false; }

    if (action === "show-problem") { cardEl.querySelector("[data-problem]").hidden = false; btn.hidden = true; }
    if (action === "hide-problem") { cardEl.querySelector("[data-problem]").hidden = true; cardEl.querySelector('[data-action="show-problem"]').hidden = false; }
    if (action === "confirm") {
      btn.disabled = true;
      const { error } = await sb.rpc("confirm_completion", { p_booking_id: id });
      if (error) { btn.disabled = false; return showMessage(msg, error.message); }
      await callFunction("release-payout", { booking_id: id }).catch(() => {}); // best effort: the scheduler also does it
      await kickEmails();
      location.reload();
    }

    if (action === "pay") {
      btn.disabled = true;
      const old = btn.textContent; btn.textContent = "Opening checkout…";
      try {
        const { data: { session } } = await sb.auth.getSession();
        const res = await fetch(`${SUPABASE_URL}/functions/v1/create-checkout`, {
          method: "POST",
          headers: { "content-type": "application/json", apikey: SUPABASE_KEY, authorization: `Bearer ${session?.access_token}` },
          body: JSON.stringify({ booking_id: id }),
        });
        const out = await res.json().catch(() => ({}));
        if (res.status === 404) throw new Error("Online payment is not set up yet (the create-checkout function is not deployed).");
        if (!res.ok || typeof out.url !== "string") throw new Error(out.error || "Could not start the payment.");
        // only ever follow a Stripe checkout address
        if (new URL(out.url).origin !== "https://checkout.stripe.com") throw new Error("Unexpected payment address.");
        location.assign(out.url);
      } catch (err) {
        btn.disabled = false; btn.textContent = old;
        showMessage(msg, err.message);
      }
      return;
    }

    if (action === "cancel") {
      if (!confirm(waselT("Cancel this booking?"))) return;
      btn.disabled = true;
      const { error } = await sb.rpc("transition_booking", { p_booking_id: id, p_new_status: "cancelled" });
      if (error) { btn.disabled = false; return showMessage(msg, error.message); }
      await callFunction("process-refund", { booking_id: id }).catch(() => {}); // best effort: only does something if it was paid
      await kickEmails();
      location.reload();
    }

    if (action === "refund") { // retry
      btn.disabled = true;
      try {
        const out = await callFunction("process-refund", { booking_id: id });
        if (out.status === "failed") throw new Error("The refund could not be sent yet. Please try again in a moment.");
        location.reload();
      } catch (err) { btn.disabled = false; showMessage(msg, err.message); }
    }
  });

  list.addEventListener("submit", async (e) => {
    const pform = e.target.closest("[data-problem]");
    if (pform) {
      e.preventDefault();
      const cardP = pform.closest("[data-id]");
      const pb = pform.querySelector("button[type=submit]"); const pl = pb.textContent;
      pb.disabled = true; pb.textContent = "Sending…";
      const { error } = await sb.rpc("report_problem", { p_booking_id: cardP.dataset.id, p_note: pform.note.value.trim() });
      if (error) { pb.disabled = false; pb.textContent = pl; return showMessage(cardP.querySelector(".action-msg") ?? pform, error.message); }
      await kickEmails();
      return location.reload();
    }
    const form = e.target.closest("[data-review]");
    if (!form) return;
    e.preventDefault();
    const cardEl = form.closest("[data-id]");
    const msg = cardEl.querySelector(".action-msg");
    if (!form.rating.value) return showMessage(msg, "Please choose a star rating first.");
    const rb = form.querySelector("button[type=submit]"); const rl = rb.textContent;
    rb.disabled = true; rb.textContent = "Saving…";
    const { error } = await sb.from("reviews").insert({
      booking_id: cardEl.dataset.id,
      rating: Number(form.rating.value),
      comment: form.comment.value.trim() || null,
    });
    if (error) { rb.disabled = false; rb.textContent = rl; return showMessage(msg, error.message); }
    location.reload();
  });
}
