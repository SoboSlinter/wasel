import { showOutcome, sb, renderChrome, params, safeNext, showMessage, getRole } from "./app.js";

// Used by login.html and signup.html (the form's data-mode says which).
const user = await renderChrome();
const form = document.getElementById("auth-form");
const mode = form.dataset.mode; // "login" | "signup"
const rawNext = params().get("next");
const portal = form.dataset.portal || "customer";           // customer | provider | admin
const loginPage = form.dataset.loginPage || "login.html";    // where confirmation / reset links bring people back
const HOME = { customer: "index.html", provider: "provider.html", admin: "admin.html" };
// Where to go after signing in: an explicit ?next wins (customer/provider), otherwise each role's own home.
const next = rawNext ? safeNext(rawNext) : HOME[portal];
// Whatever the page, an admin ends up in admin and a provider in their dashboard unless they asked for something specific.
async function destination(userId) {
  if (portal === "admin") return HOME.admin;
  if (rawNext) return next;
  const role = await getRole(userId);
  return role === "admin" ? HOME.admin : role === "provider" ? HOME.provider : next;
}
const msg = document.getElementById("auth-msg");
const extra = document.getElementById("auth-extra");
const notice = document.getElementById("auth-notice");

if (user && !params().get("reset")) {
  // already signed in: an admin page only lets admins through
  if (portal === "admin" && (await getRole(user.id)) !== "admin") await sb.auth.signOut();
  else location.replace(await destination(user.id));
}

// notices after coming back from an email link
if (notice) {
  if (params().get("confirmed")) showMessage(notice, "Email confirmed. You can log in now.", "ok");
  if (params().get("reset")) showMessage(notice, "Password changed. Log in with your new password.", "ok");
}

// keep ?next=... when moving between pages
if (rawNext) {
  for (const a of document.querySelectorAll("[data-keep-next]")) a.href += (a.href.includes("?") ? "&" : "?") + "next=" + encodeURIComponent(rawNext);
}

// Show / hide password
for (const btn of document.querySelectorAll("[data-toggle-pw]")) {
  btn.addEventListener("click", () => {
    const input = document.getElementById(btn.dataset.togglePw);
    const show = input.type === "password";
    input.type = show ? "text" : "password";
    btn.textContent = show ? "Hide" : "Show";
    btn.setAttribute("aria-pressed", String(show));
  });
}

// Plain-English errors
function friendly(error) {
  const m = (error.message || "").toLowerCase(), c = error.code || "";
  if (c === "invalid_credentials" || m.includes("invalid login credentials")) return "Wrong email or password.";
  if (c === "email_not_confirmed" || m.includes("not confirmed")) return "Please confirm your email first. Check your inbox for the link.";
  if (c === "user_already_exists" || m.includes("already registered")) return "An account with this email already exists. Log in instead.";
  if (c === "over_email_send_rate_limit" || c === "over_request_rate_limit" || error.status === 429) return "Too many attempts. Wait a minute and try again.";
  if (c === "weak_password") return error.message;
  if (m.includes("failed to fetch") || m.includes("network")) return "Can't reach the server. Check your internet connection.";
  return error.message || "Something went wrong. Try again.";
}

// "Resend confirmation email" with a 30 second cooldown
function offerResend(email) {
  extra.innerHTML = `<button type="button" class="btn btn-sm btn-outline" id="resend">Resend confirmation email</button>`;
  const btn = document.getElementById("resend");
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    const target = new URL(loginPage, location.href); target.searchParams.set("confirmed", "1");
    if (rawNext) target.searchParams.set("next", rawNext);
    const { error } = await sb.auth.resend({ type: "signup", email, options: { emailRedirectTo: target.href } });
    if (error) { btn.disabled = false; return showMessage(msg, friendly(error)); }
    showMessage(msg, "Sent again. Check your inbox (and spam folder).", "ok");
    let left = 30;
    const timer = setInterval(() => {
      btn.textContent = `Resend in ${--left}s`;
      if (left <= 0) { clearInterval(timer); btn.textContent = "Resend confirmation email"; btn.disabled = false; }
    }, 1000);
  });
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  showMessage(msg, "");
  extra.innerHTML = "";
  if (notice) showMessage(notice, "");
  const btn = form.querySelector("button[type=submit]");
  const label = btn.textContent;
  const reset = () => { btn.disabled = false; btn.textContent = label; };
  btn.disabled = true;
  btn.textContent = "Please wait…";

  const email = form.email.value.trim();
  const password = form.password.value;

  if (mode === "login") {
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) {
      reset();
      showMessage(msg, friendly(error));
      if (error.code === "email_not_confirmed" || (error.message || "").toLowerCase().includes("not confirmed")) offerResend(email);
      return;
    }
    // admin page: only real admins may stay signed in here
    const uid = (await sb.auth.getSession()).data.session?.user.id;
    if (portal === "admin" && (await getRole(uid)) !== "admin") {
      await sb.auth.signOut();
      reset();
      return showMessage(msg, "This account does not have admin access.");
    }
    return location.assign(await destination(uid));
  }

  if (password.length < 8) { reset(); return showMessage(msg, "Choose a password with at least 8 characters."); }
  if (form.password2 && form.password2.value !== password) { reset(); return showMessage(msg, "The two passwords don't match."); }

  const target = new URL(loginPage, location.href); target.searchParams.set("confirmed", "1");
  if (rawNext) target.searchParams.set("next", rawNext);
  else if (portal === "provider") target.searchParams.set("next", "provider.html");
  const { data, error } = await sb.auth.signUp({
    email,
    password,
    options: { data: { full_name: form.full_name.value.trim(), lang: window.waselLang === "es" ? "es" : "en" }, emailRedirectTo: target.href },
  });
  if (error) {
    reset();
    showMessage(msg, friendly(error));
    return showOutcome({ ok: false, title: "Sorry, we could not create your account", text: `${friendly(error)} Please check your details and try again. If it keeps happening, contact us.` });
  }

  // With email confirmation on, an already-registered address comes back as a user with no identities.
  if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
    reset();
    showMessage(msg, "An account with this email already exists. Log in instead, or use “Forgot password”.");
    return showOutcome({ ok: false, title: "Sorry, we could not create your account", text: "An account with this email already exists. Log in instead, or use “Forgot password”." });
  }
  if (data.session) { // confirmation is off: already signed in
    await showOutcome({ ok: true, title: "Your account was created successfully", text: "Welcome to Wasel. We are taking you to your account." });
    return location.assign(portal === "provider" && !rawNext ? "provider.html" : next);
  }

  reset();
  // hide the fields but keep the message area (it lives inside the form)
  for (const el of form.querySelectorAll(".field, button[type=submit]")) el.hidden = true;
  showMessage(msg, `We sent a confirmation link to ${email}. Click it to finish signing up.`, "ok");
  offerResend(email);
  showOutcome({ ok: true, wait: false, title: "Your account was created successfully", text: `One last step: we sent a confirmation link to ${email}. Open it to finish signing up. Check your spam folder if you do not see it.` });
});
