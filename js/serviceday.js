// The day of the service: messages (open from 1 hour before the start), photos of the finished work, and the 1-hour rules.
import { sb, esc, friendlyMessage, showMessage, prepareImage } from "./app.js";

export const WORK_BUCKET = "work-photos";
const HOUR = 3600e3;

// the last hour before the start (and any time after it): customers and providers can no longer cancel
export const lastHour = (iso) => Date.now() > new Date(iso).getTime() - HOUR;
// messages are open from 1 hour before the start while the booking is confirmed or in progress
export const chatOpen = (b) => ["confirmed", "in_progress"].includes(b.status) && lastHour(b.scheduled_at);
export const mapsUrl = (b) => "https://www.google.com/maps/dir/?api=1&destination=" +
  encodeURIComponent([b.customer_address, b.customer_city, "TX", b.customer_zip_code].filter(Boolean).join(", "));

const fmtTime = (iso) => new Date(iso).toLocaleString(window.waselLocale, { timeZone: "America/Chicago", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

// the box for one booking: shows the conversation, and the form while messages are open
export function chatBox(b) {
  if (!["confirmed", "in_progress", "completed"].includes(b.status)) return "";
  if (b.status === "confirmed" && !chatOpen(b)) {
    const opens = new Date(new Date(b.scheduled_at).getTime() - HOUR).toLocaleTimeString(window.waselLocale, { timeZone: "America/Chicago", hour: "numeric", minute: "2-digit" });
    return `<div class="muted small chat-note" style="margin-top:10px">💬 Messages with the ${b.customer ? "customer" : "provider"} open 1 hour before the start (at ${esc(opens)}).</div>`;
  }
  return `<div class="chat" data-chat="${esc(b.id)}" data-open="${chatOpen(b) ? "1" : ""}"></div>`;
}

export function mountChats(root, myId, otherName = "Other person") {
  root.querySelectorAll("[data-chat]").forEach((el) => mountChat(el, el.dataset.chat, myId, otherName, !!el.dataset.open));
}

async function mountChat(el, bookingId, myId, otherName, open) {
  let last = "";
  async function draw(keepFocus) {
    const { data, error } = await sb.from("booking_messages").select("id, sender_id, body, created_at").eq("booking_id", bookingId).order("created_at");
    if (error) return;
    const rows = data ?? [];
    if (!rows.length && !open) { el.innerHTML = ""; return; }
    const sig = rows.map((r) => r.id).join(",");
    const list = el.querySelector(".chat-list");
    if (list && sig === last) return;
    last = sig;
    const typed = el.querySelector("[name=body]")?.value ?? "";
    el.innerHTML = `<div class="chat-title small"><strong>💬 Messages</strong></div>
      <div class="chat-list" role="log" aria-live="polite">${rows.length ? rows.map((r) => `<div class="chat-msg ${r.sender_id === myId ? "mine" : "theirs"}"><div class="chat-body">${esc(r.body)}</div><div class="chat-meta">${r.sender_id === myId ? "You" : esc(otherName)} · ${esc(fmtTime(r.created_at))}</div></div>`).join("") : '<div class="muted small">No messages yet.</div>'}</div>
      ${open ? `<form class="chat-form"><input name="body" maxlength="1000" autocomplete="off" placeholder="Write a message" aria-label="Message"><button class="btn btn-sm" type="submit">Send</button></form><div class="chat-msg-err" hidden></div>` : `<div class="muted small">This conversation is closed.</div>`}`;
    const input = el.querySelector("[name=body]");
    if (input) { input.value = typed; if (keepFocus) input.focus(); }
    const lst = el.querySelector(".chat-list"); if (lst) lst.scrollTop = lst.scrollHeight;
  }
  el.addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = e.target.closest(".chat-form"); if (!f) return;
    const body = f.body.value.trim(), err = el.querySelector(".chat-msg-err");
    if (!body) return showMessage(err, "Write a message first.");
    f.querySelector("button").disabled = true;
    const { error } = await sb.rpc("send_booking_message", { p_booking_id: bookingId, p_body: body });
    if (error) { f.querySelector("button").disabled = false; return showMessage(err, friendlyMessage(error.message)); }
    f.body.value = ""; last = ""; await draw(true);
  });
  await draw(false);
  if (open) { const t = setInterval(() => { if (!el.isConnected) return clearInterval(t); draw(false); }, 10000); }
}

// ---------- photos of the finished work ----------
async function signed(paths) {
  if (!paths.length) return new Map();
  const { data } = await sb.storage.from(WORK_BUCKET).createSignedUrls(paths, 600);
  return new Map((data ?? []).map((x) => [x.path, x.signedUrl]));
}

// editable = the provider while the job is in progress; otherwise just a gallery
export async function mountWorkPhotos(el, { userId, bookingId, editable = false, onChange }) {
  async function draw() {
    const { data, error } = await sb.from("booking_work_photos").select("id, storage_path").eq("booking_id", bookingId).order("created_at");
    if (error) { el.innerHTML = ""; return; }
    const rows = data ?? [];
    const urls = await signed(rows.map((r) => r.storage_path));
    el.innerHTML = `${rows.length || editable ? `<div class="small" style="margin-top:10px"><strong>Photos of the finished work</strong>${editable ? ` <span class="muted">(add at least one before you mark the job completed)</span>` : ""}</div>` : ""}
      ${rows.length ? `<div class="work-photos">${rows.map((r) => `<figure data-id="${esc(r.id)}" data-path="${esc(r.storage_path)}"><a href="${esc(urls.get(r.storage_path) ?? "#")}" target="_blank" rel="noopener"><img src="${esc(urls.get(r.storage_path) ?? "")}" alt="Photo of the finished work" loading="lazy"></a>${editable ? `<button type="button" class="btn btn-sm btn-danger" data-wp="del" aria-label="Remove photo">×</button>` : ""}</figure>`).join("")}</div>` : ""}
      ${editable ? `<div class="doc-add"><input type="file" accept="image/jpeg,image/png,image/webp" multiple data-wp-file aria-label="Choose photos of the work"><button type="button" class="btn btn-sm" data-wp="add">Upload photos</button><button type="button" class="btn btn-sm btn-outline" data-wp="camera">Take a photo</button><input type="file" accept="image/*" capture="environment" hidden data-wp-cam aria-label="Take a photo of the work"></div><div class="wp-msg" hidden></div>` : ""}`;
  }
  await draw();
  if (!editable) return;
  el.addEventListener("change", (e) => { if (e.target.matches("[data-wp-cam]") && e.target.files.length) el.querySelector('[data-wp="add"]').click(); });
  el.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-wp]"); if (!b) return;
    const msg = el.querySelector(".wp-msg");
    if (b.dataset.wp === "camera") { el.querySelector("[data-wp-cam]").click(); return; }
    if (b.dataset.wp === "add") {
      const files = [...el.querySelector("[data-wp-file]").files, ...el.querySelector("[data-wp-cam]").files];
      if (!files.length) return showMessage(msg, "Choose a photo first.");
      b.disabled = true;
      for (const file of files) {
        try {
          const blob = await prepareImage(file);
          const path = `${userId}/${bookingId}/${crypto.randomUUID()}.jpg`;
          const up = await sb.storage.from(WORK_BUCKET).upload(path, blob, { contentType: "image/jpeg", upsert: false });
          if (up.error) throw new Error(up.error.message);
          const { error } = await sb.from("booking_work_photos").insert({ booking_id: bookingId, storage_path: path });
          if (error) { await sb.storage.from(WORK_BUCKET).remove([path]); throw new Error(error.message); }
        } catch (err) { b.disabled = false; await draw(); onChange?.(); return showMessage(el.querySelector(".wp-msg"), friendlyMessage(err.message)); }
      }
      el.querySelectorAll("[data-wp-file],[data-wp-cam]").forEach((i) => { i.value = ""; });
      await draw(); onChange?.();
    }
    if (b.dataset.wp === "del") {
      const fig = b.closest("figure");
      const { error } = await sb.from("booking_work_photos").delete().eq("id", fig.dataset.id);
      if (error) return showMessage(msg, friendlyMessage(error.message));
      await sb.storage.from(WORK_BUCKET).remove([fig.dataset.path]);
      await draw(); onChange?.();
    }
  });
}
