// Take a photo with the device camera, with a check that the camera really works.
// Used next to every "Choose from files" picker (provider documents, service photos, photos of the finished work).
// Nothing here is required: a person can always skip the camera and pick a file, or add no photo at all.
import { esc } from "./app.js";

// Friendly text for every way a camera can fail.
function explain(err) {
  const n = err?.name ?? "";
  if (n === "insecure") return "The camera only works on a secure (https) page. You can choose a photo from your files instead.";
  if (n === "unsupported") return "This browser cannot use the camera. You can choose a photo from your files instead.";
  if (n === "NotAllowedError" || n === "SecurityError") return "The camera is blocked. Allow the camera for this site in your browser settings, or choose a photo from your files instead.";
  if (n === "NotFoundError" || n === "OverconstrainedError") return "No camera was found on this device. You can choose a photo from your files instead.";
  if (n === "NotReadableError" || n === "AbortError") return "The camera is busy in another app. Close that app and try again, or choose a photo from your files instead.";
  return "The camera did not start. You can try again, or choose a photo from your files instead.";
}

// Is there a camera, and does it start? Resolves { ok, message }. Stops the camera right away.
export async function checkCamera() {
  if (!window.isSecureContext) return { ok: false, message: explain({ name: "insecure" }) };
  if (!navigator.mediaDevices?.getUserMedia) return { ok: false, message: explain({ name: "unsupported" }) };
  try {
    const s = await navigator.mediaDevices.getUserMedia({ video: true });
    s.getTracks().forEach((t) => t.stop());
    return { ok: true, message: "" };
  } catch (e) { return { ok: false, message: explain(e) }; }
}

// Opens a live camera preview. Resolves { file } after "Take photo", { cancelled: true }, or { error: text }.
export async function takePhoto() {
  if (!window.isSecureContext) return viaInput("insecure");
  if (!navigator.mediaDevices?.getUserMedia) return viaInput("unsupported");
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" }, width: { ideal: 1920 } }, audio: false });
  } catch (e) { return { error: explain(e) }; }

  return new Promise((resolve) => {
    const dlg = document.createElement("dialog");
    dlg.className = "camera-dialog";
    dlg.innerHTML = `<h2 style="font-size:1.125rem;margin:0 0 8px">Take a photo</h2>
      <video playsinline muted autoplay aria-label="Camera preview"></video>
      <p class="small muted" data-cam-msg style="margin:6px 0 0">Point the camera, then press “Take photo”.</p>
      <div class="btn-row" style="margin-top:10px;justify-content:flex-end">
        <button type="button" class="btn btn-sm btn-outline" data-cam="cancel">Cancel</button>
        <button type="button" class="btn btn-sm" data-cam="shoot" disabled>Take photo</button></div>`;
    document.body.appendChild(dlg);
    const video = dlg.querySelector("video");
    video.srcObject = stream;
    const finish = (out) => { stream.getTracks().forEach((t) => t.stop()); dlg.close(); dlg.remove(); resolve(out); };
    const shoot = dlg.querySelector('[data-cam="shoot"]');
    // the button works only once the picture is really moving: that proves the camera works
    video.addEventListener("loadeddata", () => { shoot.disabled = false; dlg.querySelector("[data-cam-msg]").textContent = "The camera works. Press “Take photo” when you are ready."; });
    stream.getVideoTracks()[0]?.addEventListener("ended", () => finish({ error: "The camera stopped. Try again, or choose a photo from your files instead." }));
    setTimeout(() => { if (shoot.disabled && dlg.isConnected) finish({ error: "The camera did not show a picture. Try again, or choose a photo from your files instead." }); }, 10000);
    dlg.querySelector('[data-cam="cancel"]').onclick = () => finish({ cancelled: true });
    dlg.addEventListener("cancel", (e) => { e.preventDefault(); finish({ cancelled: true }); });
    shoot.onclick = () => {
      const w = video.videoWidth, h = video.videoHeight;
      if (!w || !h) return;
      const scale = Math.min(1, 1600 / Math.max(w, h));
      const c = document.createElement("canvas"); c.width = Math.round(w * scale); c.height = Math.round(h * scale);
      c.getContext("2d").drawImage(video, 0, 0, c.width, c.height);
      c.toBlob((b) => {
        if (!b) return finish({ error: "The photo could not be saved. Please try again." });
        finish({ file: new File([b], `camera-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.jpg`, { type: "image/jpeg" }) });
      }, "image/jpeg", 0.9);
    };
    dlg.showModal();
  });
}

// Phones can still open their camera app through a file input, even when the live preview is not possible.
function viaInput(why) {
  const touch = matchMedia("(pointer: coarse)").matches;
  if (!touch) return Promise.resolve({ error: explain({ name: why }) });
  return new Promise((resolve) => {
    const i = Object.assign(document.createElement("input"), { type: "file", accept: "image/*" });
    i.setAttribute("capture", "environment");
    i.onchange = () => resolve(i.files[0] ? { file: i.files[0] } : { cancelled: true });
    i.click();
  });
}

// Puts a File into an <input type=file>, then tells the page (as if the person had picked it).
export function setInputFile(input, file, { fire = true } = {}) {
  const dt = new DataTransfer();
  dt.items.add(file);
  input.files = dt.files;
  if (fire) input.dispatchEvent(new Event("change", { bubbles: true }));
}

// One call for the buttons: opens the camera and returns the File, or shows why it did not work in `say(text)`.
export async function photoFromCamera(say) {
  say?.("");
  const r = await takePhoto();
  if (r.file) return r.file;
  if (r.error) say?.(r.error);
  return null;
}

export const CAMERA_HINT = "Photos are optional: you can use the camera, pick a file, or skip this and add them later.";
export { esc };
