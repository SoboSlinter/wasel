import { sb, showMessage } from "./app.js";

// Admin log in page: "I have an invite code". The code is checked first, then sent with the sign-up.
// The database is the real gatekeeper: without a valid, unused, unexpired code the account is not created.
const form = document.getElementById("join-form");
if (form) {
  const msg = document.getElementById("join-msg");
  const err = (e) => {
    const m = (e?.message || "").toLowerCase(), c = e?.code || "";
    if (c === "user_already_exists" || m.includes("already registered")) return "An account with this email already exists. Log in above instead.";
    if (c === "weak_password") return e.message;
    if (e?.status === 429 || c === "over_email_send_rate_limit" || c === "over_request_rate_limit") return "Too many attempts. Wait a minute and try again.";
    if (m.includes("failed to fetch") || m.includes("network")) return "Can't reach the server. Check your internet connection.";
    if (m.includes("database error")) return "The invite code was not accepted. Ask the main admin for a new one.";
    return e?.message || "Something went wrong. Try again.";
  };

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    showMessage(msg, "");
    const $ = (id) => document.getElementById(id);
    const name = $("j-name").value.trim(), email = $("j-email").value.trim(), password = $("j-pass").value, code = $("j-code").value.trim();
    if (!name) return showMessage(msg, "Please enter your full name.");
    if (!email) return showMessage(msg, "Please enter your email.");
    if (password.length < 8) return showMessage(msg, "Choose a password with at least 8 characters.");
    if (password !== $("j-pass2").value) return showMessage(msg, "The two passwords don't match.");
    if (!code) return showMessage(msg, "Enter the invite code you were given.");

    const btn = form.querySelector("button[type=submit]");
    const label = btn.textContent;
    btn.disabled = true; btn.textContent = "Please wait…";
    const reset = () => { btn.disabled = false; btn.textContent = label; };

    const { data: valid, error: checkErr } = await sb.rpc("check_admin_invite", { p_code: code });
    if (checkErr) { reset(); return showMessage(msg, err(checkErr)); }
    if (!valid) { reset(); return showMessage(msg, "This invite code is not valid. It may have been used, cancelled or expired. Ask the main admin for a new one."); }

    const target = new URL("admin-login.html", location.href); target.searchParams.set("confirmed", "1");
    const { data, error } = await sb.auth.signUp({
      email, password,
      options: { data: { full_name: name, lang: window.waselLang === "es" ? "es" : "en", admin_invite: code }, emailRedirectTo: target.href },
    });
    if (error) { reset(); return showMessage(msg, err(error)); }
    if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
      reset();
      return showMessage(msg, "An account with this email already exists. Log in above instead, or use “Forgot password”.");
    }
    if (data.session) return location.assign("admin.html"); // email confirmation is off: already signed in
    for (const el of form.querySelectorAll(".field, button[type=submit]")) el.hidden = true;
    showMessage(msg, `We sent a confirmation link to ${email}. Click it, then log in above with your new admin account.`, "ok");
  });
}
