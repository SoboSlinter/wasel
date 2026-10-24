// Private documents (ID, license, insurance, service papers). Stored in the PRIVATE bucket "provider-docs":
// only the owner and the admins can open them (through short-lived signed links).
import { sb, esc, friendlyMessage, showMessage } from "./app.js";
import { photoFromCamera, setInputFile } from "./capture.js";

export const DOC_BUCKET = "provider-docs";
export const MAX_DOC_BYTES = 10 * 1024 * 1024;
const OK_TYPES = ["application/pdf", "image/jpeg", "image/png", "image/webp"];
export const KIND_LABEL = { id: "ID", license: "License", insurance: "Proof of insurance", other: "Other document", service: "Service document" };
export const PROVIDER_KINDS = [["id", "ID (driver license, passport…)"], ["license", "Business or trade license"], ["insurance", "Proof of insurance"], ["other", "Other document"]];

export function checkFile(f) {
  if (!f) return "Choose a file first.";
  if (!OK_TYPES.includes(f.type)) return "Documents must be a PDF or a photo (JPG, PNG or WebP).";
  if (f.size > MAX_DOC_BYTES) return "That file is larger than 10 MB.";
  if (f.size < 1) return "That file is empty.";
  return "";
}

const safeName = (n) => (n || "document").replace(/[^A-Za-z0-9._-]+/g, "_").slice(-80) || "document";

// uploads the file, then records it. Returns an error text, or "" when it worked.
export async function uploadDoc(userId, providerId, { kind, serviceId = null, file }) {
  const bad = checkFile(file);
  if (bad) return bad;
  const path = `${userId}/${kind}/${crypto.randomUUID()}-${safeName(file.name)}`;
  const up = await sb.storage.from(DOC_BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) return friendlyMessage(up.error.message);
  const { error } = await sb.from("provider_documents").insert({
    provider_id: providerId, service_id: serviceId, kind, storage_path: path, file_name: file.name.slice(0, 150), size_bytes: file.size,
  });
  if (error) { await sb.storage.from(DOC_BUCKET).remove([path]); return friendlyMessage(error.message); }
  return "";
}

// same as uploadDoc, but also returns the new document's id: { error, id }
export async function uploadDocWithId(userId, providerId, { kind, file }) {
  const bad = checkFile(file);
  if (bad) return { error: bad };
  const path = `${userId}/${kind}/${crypto.randomUUID()}-${safeName(file.name)}`;
  const up = await sb.storage.from(DOC_BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) return { error: friendlyMessage(up.error.message) };
  const { data, error } = await sb.from("provider_documents").insert({
    provider_id: providerId, service_id: null, kind, storage_path: path, file_name: file.name.slice(0, 150), size_bytes: file.size,
  }).select("id").single();
  if (error) { await sb.storage.from(DOC_BUCKET).remove([path]); return { error: friendlyMessage(error.message) }; }
  return { id: data.id, path };
}
export async function removeDocById(id, path) {
  await sb.from("provider_documents").delete().eq("id", id);
  if (path) await sb.storage.from(DOC_BUCKET).remove([path]);
}

// opens a private document in a new tab through a signed link that expires in 10 minutes
export async function openDoc(path) {
  const w = window.open("about:blank", "_blank");
  const { data, error } = await sb.storage.from(DOC_BUCKET).createSignedUrl(path, 600);
  if (error || !data?.signedUrl) { w?.close(); return friendlyMessage(error?.message ?? "Could not open the document."); }
  if (w) w.location.href = data.signedUrl; else location.href = data.signedUrl;
  return "";
}

const sizeText = (b) => (b >= 1048576 ? (b / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(b / 1024)) + " KB");

// A list of the documents already uploaded, with an upload form. serviceId=null means "the business documents".
export async function mountDocs(el, { userId, providerId, serviceId = null, kinds = PROVIDER_KINDS, locked = false, onChange }) {
  async function draw() {
    let q = sb.from("provider_documents").select("id, kind, storage_path, file_name, size_bytes, created_at").eq("provider_id", providerId).order("created_at");
    q = serviceId ? q.eq("service_id", serviceId) : q.is("service_id", null);
    const { data, error } = await q;
    if (error) { el.innerHTML = `<div class="alert alert-error">${esc(friendlyMessage(error.message))}</div>`; return; }
    const rows = data ?? [];
    el.innerHTML = `
      ${rows.length ? `<ul class="doc-list">${rows.map((d) => `
        <li data-id="${esc(d.id)}" data-path="${esc(d.storage_path)}"><span class="doc-kind">${esc(KIND_LABEL[d.kind] ?? d.kind)}</span>
          <span class="doc-name">${esc(d.file_name)}${d.size_bytes ? ` <span class="muted small">· ${esc(sizeText(d.size_bytes))}</span>` : ""}</span>
          <button type="button" class="btn btn-sm btn-outline" data-doc="view">View</button>
          ${locked && ["id", "license", "insurance"].includes(d.kind) ? "" : `<button type="button" class="btn btn-sm btn-danger" data-doc="del">Remove</button>`}</li>`).join("")}</ul>`
        : `<p class="muted small" style="margin:0 0 8px">No documents uploaded yet.</p>`}
      <div class="doc-add">
        ${kinds.length > 1 ? `<select data-doc-kind aria-label="Document type">${kinds.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("")}</select>` : ""}
        <input type="file" data-doc-file accept="application/pdf,image/jpeg,image/png,image/webp" aria-label="Choose a document from your files">
        <button type="button" class="btn btn-sm btn-outline" data-doc="camera">Take a photo</button>
        <button type="button" class="btn btn-sm" data-doc="add">Upload</button>
      </div>
      <p class="hint" style="margin:6px 0 0">PDF or photo, up to 10 MB each: choose a file or take a photo with your camera. Only you and the Wasel admins can open your documents.</p>
      <div class="doc-msg" hidden></div>`;
  }
  await draw();
  el.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-doc]");
    if (!b) return;
    const msg = el.querySelector(".doc-msg");
    if (b.dataset.doc === "view") {
      const err = await openDoc(b.closest("li").dataset.path);
      if (err) showMessage(msg, err);
    }
    if (b.dataset.doc === "del") {
      if (!confirm(window.waselT ? window.waselT("Remove this document?") : "Remove this document?")) return;
      const li = b.closest("li");
      const { error } = await sb.from("provider_documents").delete().eq("id", li.dataset.id);
      if (error) return showMessage(msg, friendlyMessage(error.message));
      await sb.storage.from(DOC_BUCKET).remove([li.dataset.path]);
      await draw(); onChange?.();
    }
    if (b.dataset.doc === "camera") {
      const f = await photoFromCamera((t) => showMessage(msg, t, "warn"));
      if (f) { setInputFile(el.querySelector("[data-doc-file]"), f, { fire: false }); showMessage(msg, "Photo ready. Press Upload to save it.", "ok"); }
      return;
    }
    if (b.dataset.doc === "add") {
      const file = el.querySelector("[data-doc-file]").files[0];
      const kind = serviceId ? "service" : (el.querySelector("[data-doc-kind]")?.value ?? kinds[0][0]);
      b.disabled = true;
      const err = await uploadDoc(userId, providerId, { kind, serviceId, file });
      b.disabled = false;
      if (err) return showMessage(msg, err);
      await draw(); onChange?.();
    }
  });
}

// For the register form: documents are picked first and uploaded after the profile exists.
export function mountDocQueue(el, kinds = PROVIDER_KINDS, { max = 8, hint = "" } = {}) {
  const items = []; // { kind, file }
  const draw = () => {
    el.innerHTML = `
      ${items.length ? `<ul class="doc-list">${items.map((it, i) => `<li><span class="doc-kind">${esc(KIND_LABEL[it.kind])}</span><span class="doc-name">${esc(it.file.name)} <span class="muted small">· ${esc(sizeText(it.file.size))}</span></span><button type="button" class="btn btn-sm btn-danger" data-q="${i}">Remove</button></li>`).join("")}</ul>` : ""}
      <div class="doc-add">
        <select data-q-kind aria-label="Document type">${kinds.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("")}</select>
        <input type="file" data-q-file accept="application/pdf,image/jpeg,image/png,image/webp" aria-label="Choose a document from your files">
        <button type="button" class="btn btn-sm btn-outline" data-q="camera">Take a photo</button>
        <button type="button" class="btn btn-sm" data-q="add">Add</button>
      </div>
      <p class="hint" style="margin:6px 0 0">PDF or photo, up to 10 MB each: choose a file or take a photo with your camera.${hint ? " " + esc(hint) : ""}</p>
      <div class="doc-msg" hidden></div>`;
  };
  draw();
  el.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-q]");
    if (!b) return;
    if (b.dataset.q === "camera") {
      const m = el.querySelector(".doc-msg");
      const f = await photoFromCamera((t) => showMessage(m, t, "warn"));
      if (f) { setInputFile(el.querySelector("[data-q-file]"), f, { fire: false }); showMessage(m, "Photo ready. Press Add to include it.", "ok"); }
      return;
    }
    if (b.dataset.q === "add") {
      const file = el.querySelector("[data-q-file]").files[0];
      const bad = checkFile(file);
      if (bad) return showMessage(el.querySelector(".doc-msg"), bad);
      if (items.length >= max) return showMessage(el.querySelector(".doc-msg"), `You can add up to ${max} documents.`);
      items.push({ kind: el.querySelector("[data-q-kind]").value, file });
      draw();
    } else { items.splice(Number(b.dataset.q), 1); draw(); }
  });
  return {
    items: () => items.slice(),
    clear: () => { items.length = 0; draw(); },
    // what is still missing for an application the admin can approve
    missing: () => [
      items.some((i) => i.kind === "id") ? null : "your ID",
      items.some((i) => i.kind === "license" || i.kind === "insurance") ? null : "a license or proof of insurance",
    ].filter(Boolean),
  };
}
