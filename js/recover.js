import { sb, renderChrome, showMessage } from "./app.js";

// forgot.html: ask for a reset email.   reset.html: choose the new password.
// Read these BEFORE any await: the client clears the link's #hash once it has used it.
const cameFromResetLink = location.hash.includes("type=recovery");
let recoveryEvent = false;
sb.auth.onAuthStateChange((event) => { if (event === "PASSWORD_RECOVERY") { recoveryEvent = true; document.dispatchEvent(new Event("recovery")); } });
await renderChrome();
const msg = document.getElementById("auth-msg");
const form = document.getElementById("auth-form");
const mode = form.dataset.mode; // "forgot" | "reset"
const PORTALS = { customer: "login.html", provider: "provider-login.html", admin: "admin-login.html" };
const portal = Object.hasOwn(PORTALS, new URLSearchParams(location.search).get("portal")) ? new URLSearchParams(location.search).get("portal") : "customer";
const backTo = PORTALS[portal];
for (const a of document.querySelectorAll("[data-back-login]")) a.href = backTo;
for (const a of document.querySelectorAll("a[href='forgot.html']")) a.href = "forgot.html?portal=" + portal;

for (const btn of document.querySelectorAll("[data-toggle-pw]")) {
  btn.addEventListener("click", () => {
    const input = document.getElementById(btn.dataset.togglePw);
    const show = input.type === "password";
    input.type = show ? "text" : "password";
    btn.textContent = show ? "Hide" : "Show";
    btn.setAttribute("aria-pressed", String(show));
  });
}

const submitBtn = form.querySelector("button[type=submit]");
const busy = (on, label) => { submitBtn.disabled = on; if (on) { submitBtn.dataset.l = submitBtn.textContent; submitBtn.textContent = "Please wait…"; } else submitBtn.textContent = label ?? submitBtn.dataset.l; };

if (mode === "forgot") {
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    showMessage(msg, "");
    busy(true);
    const email = form.email.value.trim();
    const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: new URL("reset.html?portal=" + portal, location.href).href });
    busy(false);
    if (error && (error.status === 429 || (error.code || "").includes("rate_limit"))) return showMessage(msg, "Too many attempts. Wait a minute and try again.");
    // Same answer whether or not the address has an account, so nobody can use this to find out who is registered.
    form.hidden = true;
    showMessage(msg, "If an account exists for that email, a reset link is on its way. It can take a minute.", "ok");
    msg.parentElement.insertBefore(msg, form);
  });
}

if (mode === "reset") {
  // The link signs the user in with a short-lived "recovery" session. Only that session may set a new password here.
  let ready = false;
  const open = () => { ready = true; form.hidden = false; showMessage(msg, ""); };
  form.hidden = true;
  if (recoveryEvent) open();
  document.addEventListener("recovery", open);
  setTimeout(async () => {
    if (ready) return;
    const { data } = await sb.auth.getSession();
    if (cameFromResetLink && data.session) return open();
    showMessage(msg, "This link is invalid or has expired. Ask for a new one.");
  }, 1500);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    showMessage(msg, "");
    const pw = form.password.value;
    if (pw.length < 8) return showMessage(msg, "Choose a password with at least 8 characters.");
    if (pw !== form.password2.value) return showMessage(msg, "The two passwords don't match.");
    busy(true);
    const { error } = await sb.auth.updateUser({ password: pw });
    if (error) {
      busy(false);
      return showMessage(msg, error.code === "same_password" ? "Choose a password you haven't used before." : error.code === "weak_password" ? error.message : "Could not change the password. The link may have expired. Ask for a new one.");
    }
    await sb.auth.signOut({ scope: "local" });
    location.assign(backTo + "?reset=1");
  });
}
