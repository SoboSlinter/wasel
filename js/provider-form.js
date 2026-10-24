// The one provider form. It is used by provider-signup.html (signed out: the first step creates the account)
// and by provider.html (a signed-in person who is not a provider yet: no account step).
import { mountAreaEditor } from "./areas.js";
import { mountDocQueue, uploadDoc } from "./docs.js";
import { sb, esc, showMessage, CATEGORIES, friendlyMessage, showOutcome } from "./app.js";

const LANGS = ["English", "Arabic", "Spanish"];
const REFERRALS = [["", "Choose…"], ["friend", "A friend or family"], ["social", "Social media"], ["search", "Online search"], ["flyer", "Flyer or in person"], ["other", "Other"]];
const DRAFT_KEY = "wasel-provider-draft";
const DRAFT_DAYS = 7;

// What the person typed is kept in this browser (never the password, never the files) while they confirm their email.
function loadDraft(email) {
  try {
    const d = JSON.parse(localStorage.getItem(DRAFT_KEY) ?? "null");
    if (!d || !email || d.email !== email.toLowerCase() || Date.now() - d.at > DRAFT_DAYS * 864e5) return null;
    return d.v;
  } catch { return null; }
}
const saveDraft = (email, v) => { try { localStorage.setItem(DRAFT_KEY, JSON.stringify({ email: email.toLowerCase(), at: Date.now(), v })); } catch { /* storage blocked */ } };
const clearDraft = () => { try { localStorage.removeItem(DRAFT_KEY); } catch { /* ignore */ } };

export function mountProviderForm(root, { user = null, afterDone }) {
  const signedOut = !user;
  const labels = signedOut
    ? ["1. Your account", "2. Your business", "3. Contact & areas", "4. Documents", "5. Trust & finish"]
    : ["1. Your business", "2. Contact & areas", "3. Documents", "4. Trust & finish"];
  const keys = signedOut ? ["account", "business", "contact", "docs", "trust"] : ["business", "contact", "docs", "trust"];
  const draft = user ? loadDraft(user.email) : null;

  root.innerHTML = `
    <h1 style="font-size:1.875rem">Become a provider</h1>
    <p class="muted">Tell customers about your business. An admin reviews every new provider before it appears on Wasel.</p>
    <ol class="steps" id="steps">${labels.map((l) => `<li>${l}</li>`).join("")}</ol>
    <form id="register" class="panel" novalidate>
      ${signedOut ? `<div class="step" data-key="account">
        <div class="field"><label for="full_name">Full name</label><input id="full_name" name="full_name" required autocomplete="name"></div>
        <div class="field"><label for="acct_email">Email</label><input id="acct_email" name="acct_email" type="email" required autocomplete="email"></div>
        <div class="field"><label for="password">Password</label><div class="pw"><input id="password" name="password" type="password" required minlength="8" autocomplete="new-password"><button type="button" data-toggle-pw="password" aria-pressed="false">Show</button></div><div class="hint">At least 8 characters.</div></div>
        <div class="field"><label for="password2">Confirm password</label><div class="pw"><input id="password2" name="password2" type="password" required minlength="8" autocomplete="new-password"><button type="button" data-toggle-pw="password2" aria-pressed="false">Show</button></div></div>
        <p class="muted small" style="margin:0">Already a provider? <a class="link" href="provider-login.html">Log in</a> · Looking to book a service? <a class="link" href="signup.html">Create a customer account</a></p>
      </div>` : ""}

      <div class="step" data-key="business" hidden>
        <div class="field"><label for="business_name">Business name</label><input id="business_name" name="business_name" required maxlength="120"></div>
        <div class="field"><label>I work as</label>
          <div class="checks"><label><input type="radio" name="business_type" value="individual"> An individual</label>
          <label><input type="radio" name="business_type" value="company"> A company</label></div></div>
        <div class="field"><label>What services do you offer? <span class="muted small">(choose at least one)</span></label>
          <div class="checks" id="cats">${CATEGORIES.map((c) => `<label><input type="checkbox" name="cat" value="${esc(c.slug)}"> ${esc(c.icon)} ${esc(c.label)}</label>`).join("")}</div></div>
        <div class="field"><label for="description">About your business</label><textarea id="description" name="description" rows="4" maxlength="1000" placeholder="What you do, what makes you different"></textarea></div>
      </div>

      <div class="step" data-key="contact" hidden>
        <div class="row2">
          <div class="field"><label for="phone">Phone</label><input id="phone" name="phone" type="tel" autocomplete="tel" required placeholder="(214) 555-0123"><div class="hint">Customers see it after you confirm a booking.</div></div>
          <div class="field"><label for="email">Business email</label><input id="email" name="email" type="email" value="${esc(user?.email ?? "")}"></div>
        </div>
        <div class="field"><label for="address">Address <span class="muted small">(optional)</span></label><input id="address" name="address" autocomplete="street-address"></div>
        <div class="row3">
          <div class="field"><label for="city">City</label><input id="city" name="city"></div>
          <div class="field"><label for="state">State</label><input id="state" name="state" value="TX" maxlength="2"></div>
          <div class="field"><label for="zip_code">ZIP code</label><input id="zip_code" name="zip_code" inputmode="numeric" maxlength="10"></div>
        </div>
        <div class="field"><label>Where do you offer your services?</label><div id="reg-areas"></div></div>
      </div>

      <div class="step" data-key="docs" hidden>
        <p style="margin-top:0">To protect customers, an admin checks every application. Please upload:</p>
        <ul class="small" style="margin:0 0 12px;padding-left:20px"><li><strong>Your ID</strong> (required)</li><li><strong>A business or trade license, or proof of insurance</strong> (required)</li><li>Anything else that shows your experience (optional)</li></ul>
        <div class="hint" style="margin-bottom:12px">Files are PDF, JPG, PNG or WebP up to 10 MB. They are stored privately: only you and Wasel administrators can open them.</div>
        <div id="reg-docs"></div>
      </div>

      <div class="step" data-key="trust" hidden>
        <p class="hint" style="margin-top:0">All optional except the agreement at the bottom. A complete profile helps the admin approve you faster and helps customers trust you.</p>
        <div class="row2">
          <div class="field"><label for="years_experience">Years of experience</label><input id="years_experience" name="years_experience" type="number" min="0" max="60" step="1"></div>
          <div class="field"><label for="website">Website or social page</label><input id="website" name="website" type="url" placeholder="https://"></div>
        </div>
        <div class="field"><label>Languages you speak</label>
          <div class="checks">${LANGS.map((l) => `<label><input type="checkbox" name="lang" value="${esc(l)}"${l === "English" ? " checked" : ""}> ${esc(l)}</label>`).join("")}</div>
          <input id="lang_other" name="lang_other" placeholder="Others, separated by commas" style="margin-top:8px"></div>
        <div class="field"><label for="license_info">License or insurance <span class="muted small">(private, only admins see it)</span></label>
          <textarea id="license_info" name="license_info" rows="2" maxlength="300" placeholder="For example: TX electrical license #12345, general liability insurance"></textarea></div>
        <div class="field"><label for="referral">How did you hear about Wasel?</label>
          <select id="referral" name="referral">${REFERRALS.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("")}</select></div>
        <div class="field"><label class="checks" style="font-weight:500"><input type="checkbox" name="terms" id="terms"> <span>I agree to the <a class="link" href="terms.html" target="_blank" rel="noopener">Terms of Service</a> and <a class="link" href="privacy.html" target="_blank" rel="noopener">Privacy Policy</a>, and I confirm I may legally offer these services.</span></label></div>
      </div>

      <div id="reg-msg" hidden></div>
      <div id="reg-extra" style="margin-top:12px"></div>
      <div class="step-btns">
        <button class="btn btn-outline" type="button" id="back" hidden>Back</button>
        <button class="btn" type="button" id="next" style="margin-left:auto">Next</button>
        <button class="btn" type="submit" id="send" hidden>${signedOut ? "Create account and apply" : "Apply to become a provider"}</button>
      </div>
    </form>`;

  const form = document.getElementById("register");
  const areaEditor = mountAreaEditor(document.getElementById("reg-areas"), draft?.areas ?? []);
  const docQueue = mountDocQueue(document.getElementById("reg-docs"));
  const stepEls = [...form.querySelectorAll(".step")], marks = [...document.querySelectorAll("#steps li")];
  const msg = document.getElementById("reg-msg"), extra = document.getElementById("reg-extra");
  let step = 0, account = user;

  // show / hide password
  for (const btn of form.querySelectorAll("[data-toggle-pw]")) {
    btn.addEventListener("click", () => {
      const input = document.getElementById(btn.dataset.togglePw), on = input.type === "password";
      input.type = on ? "text" : "password"; btn.textContent = on ? "Hide" : "Show"; btn.setAttribute("aria-pressed", String(on));
    });
  }

  const show = (n, first) => {
    step = n;
    stepEls.forEach((el, i) => (el.hidden = i !== n));
    marks.forEach((el, i) => { el.className = i === n ? "on" : i < n ? "done" : ""; });
    document.getElementById("back").hidden = n === 0;
    document.getElementById("next").hidden = n === stepEls.length - 1;
    document.getElementById("send").hidden = n !== stepEls.length - 1;
    showMessage(msg, "");
    if (!first) window.scrollTo({ top: 0 });
  };

  // restore what was typed before the email was confirmed, then ask only for the files
  if (draft) {
    for (const [k, val] of Object.entries(draft.fields ?? {})) if (form[k] && typeof val === "string") form[k].value = val;
    for (const box of form.querySelectorAll("[name=cat]")) box.checked = (draft.cats ?? []).includes(box.value);
    for (const box of form.querySelectorAll("[name=lang]")) box.checked = (draft.langs ?? []).includes(box.value);
    const radio = form.querySelector(`[name=business_type][value="${draft.type}"]`); if (radio) radio.checked = true;
    show(keys.indexOf("docs"), true);
    showMessage(msg, "Welcome back. Your details are saved. Add your ID and a license or proof of insurance to finish.", "ok");
  } else show(0, true);

  const key = () => keys[step];
  // returns an error text for a step, or "" when it is fine
  const check = (k) => {
    if (k === "account") {
      if (!form.full_name.value.trim()) return "Please enter your name.";
      if (!form.acct_email.checkValidity() || !form.acct_email.value.trim()) return "Please enter a valid email address.";
      if (form.password.value.length < 8) return "Choose a password with at least 8 characters.";
      if (form.password2.value !== form.password.value) return "The two passwords don't match.";
    }
    if (k === "business") {
      if (!form.business_name.value.trim()) return "Enter your business name.";
      if (!form.business_type.value) return "Choose whether you work as an individual or a company.";
      if (!form.querySelectorAll("[name=cat]:checked").length) return "Choose at least one service category.";
    }
    if (k === "contact") {
      const digits = form.phone.value.replace(/\D/g, "");
      if (digits.length < 10 || digits.length > 11 || (digits.length === 11 && digits[0] !== "1")) return "Enter a valid US phone number, like (214) 555-0123.";
      if (form.email.value.trim() && !form.email.checkValidity()) return "That business email does not look right.";
      if (form.zip_code.value.trim() && !/^\d{5}(-\d{4})?$/.test(form.zip_code.value.trim())) return "ZIP code should be 5 digits.";
      if (form.state.value.trim() && !/^[A-Za-z]{2}$/.test(form.state.value.trim())) return "State should be 2 letters, like TX.";
      if (!areaEditor.flush()) return "Fix the area you typed, or clear it.";
      if (!areaEditor.get().length) return "Add at least one city or ZIP code where you offer your services.";
    }
    if (k === "docs") {
      const miss = docQueue.missing();
      if (miss.length === 2) return "Please add your ID and a license or proof of insurance.";
      if (miss.length) return miss[0] === "your ID" ? "Please add your ID." : "Please add a license or proof of insurance.";
    }
    if (k === "trust") {
      const y = form.years_experience.value;
      if (y !== "" && (!/^\d+$/.test(y) || Number(y) > 60)) return "Years of experience must be a number from 0 to 60.";
      const w = form.website.value.trim();
      if (w && !/^https?:\/\/\S{3,190}$/.test(w)) return "The website must start with http:// or https://";
      if (!form.terms.checked) return "Please agree to the Terms and Privacy Policy to continue.";
    }
    return "";
  };

  document.getElementById("next").addEventListener("click", () => {
    const err = check(key());
    if (err) return showMessage(msg, err);
    // the business email defaults to the account email
    if (key() === "account" && !form.email.value.trim()) form.email.value = form.acct_email.value.trim();
    show(step + 1);
  });
  document.getElementById("back").addEventListener("click", () => show(step - 1));

  const answers = () => {
    const fields = {};
    for (const n of ["business_name", "description", "phone", "email", "address", "city", "state", "zip_code", "years_experience", "website", "lang_other", "license_info", "referral"]) fields[n] = form[n].value;
    return {
      fields, type: form.business_type.value, areas: areaEditor.get(),
      cats: [...form.querySelectorAll("[name=cat]:checked")].map((x) => x.value),
      langs: [...form.querySelectorAll("[name=lang]:checked")].map((x) => x.value),
    };
  };

  // "Resend confirmation email" with a 30 second cooldown
  function offerResend(email) {
    extra.innerHTML = `<button type="button" class="btn btn-sm btn-outline" id="resend">Resend confirmation email</button>`;
    const btn = document.getElementById("resend");
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      const target = new URL("provider-login.html", location.href); target.searchParams.set("confirmed", "1"); target.searchParams.set("next", "provider.html");
      const { error } = await sb.auth.resend({ type: "signup", email, options: { emailRedirectTo: target.href } });
      if (error) { btn.disabled = false; return showMessage(msg, friendlyMessage(error.message)); }
      showMessage(msg, "Sent again. Check your inbox (and spam folder).", "ok");
      let left = 30;
      const timer = setInterval(() => {
        btn.textContent = `Resend in ${--left}s`;
        if (left <= 0) { clearInterval(timer); btn.textContent = "Resend confirmation email"; btn.disabled = false; }
      }, 1000);
    });
  }

  // 1) the account (only when signed out). Returns the signed-in user, or null when the email must be confirmed first.
  async function createAccount() {
    const email = form.acct_email.value.trim();
    const target = new URL("provider-login.html", location.href); target.searchParams.set("confirmed", "1"); target.searchParams.set("next", "provider.html");
    const { data, error } = await sb.auth.signUp({
      email, password: form.password.value,
      options: { data: { full_name: form.full_name.value.trim(), lang: window.waselLang === "es" ? "es" : "en" }, emailRedirectTo: target.href },
    });
    if (error) throw new Error(error.code === "user_already_exists" || /already registered/i.test(error.message) ? "An account with this email already exists. Log in instead, or use “Forgot password”." : friendlyMessage(error.message));
    if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) throw new Error("An account with this email already exists. Log in instead, or use “Forgot password”.");
    return data.session?.user ?? null;
  }

  // 2) the business, its areas and its documents (needs a signed-in user)
  async function applyAsProvider(u) {
    const v = (n) => form[n].value.trim() || null;
    const langs = [...form.querySelectorAll("[name=lang]:checked")].map((x) => x.value)
      .concat(form.lang_other.value.split(",").map((x) => x.trim()).filter(Boolean)).slice(0, 8);
    const { error } = await sb.rpc("register_provider", {
      p_business_name: form.business_name.value.trim(),
      p_business_type: form.business_type.value,
      p_categories: [...form.querySelectorAll("[name=cat]:checked")].map((x) => x.value),
      p_phone: form.phone.value.trim(),
      p_accept_terms: form.terms.checked,
      p_description: v("description"), p_email: v("email"),
      p_address: v("address"), p_city: v("city"), p_state: v("state"), p_zip_code: v("zip_code"),
      p_years_experience: form.years_experience.value === "" ? null : Number(form.years_experience.value),
      p_license_info: v("license_info"), p_languages: langs.length ? langs : null,
      p_website: v("website"), p_referral_source: v("referral"),
    });
    if (error) throw new Error(error.message);
    const { error: areaErr } = await sb.rpc("set_service_areas", { p_areas: areaEditor.get() });
    if (areaErr) sessionStorage.setItem("areaWarn", areaErr.message);
    const { data: mine } = await sb.from("provider_profiles").select("id").eq("user_id", u.id).maybeSingle();
    let docFail = 0;
    for (const it of docQueue.items()) if (!mine || (await uploadDoc(u.id, mine.id, { kind: it.kind, file: it.file }))) docFail++;
    if (docFail) sessionStorage.setItem("docWarn", String(docFail));
    clearDraft();
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    for (let i = 0; i < stepEls.length; i++) {
      const err = check(keys[i]);
      if (err) { show(i); return showMessage(msg, err); }
    }
    const btn = document.getElementById("send"), label = btn.textContent;
    btn.disabled = true; btn.textContent = "Please wait…";
    extra.innerHTML = "";
    try {
      if (!account) {
        account = await createAccount();   // created once; if the next step fails the person can simply press the button again
        if (!account) {
          // email confirmation is on: keep the answers, ask the person to confirm, and ask for the files after they log in
          const email = form.acct_email.value.trim();
          saveDraft(email, answers());
          for (const el of form.querySelectorAll(".step, .step-btns, #steps")) el.hidden = true;
          document.getElementById("steps").hidden = true;
          showMessage(msg, `We sent a confirmation link to ${email}. Click it, log in, and you will come back to this form with your details already filled in. You only need to add your documents.`, "ok");
          offerResend(email);
          showOutcome({ ok: true, wait: false, title: "Your account was created successfully", text: `We sent a confirmation link to ${email}. Click it, log in, and you will come back to this form with your details already filled in. You only need to add your documents.` });
          return;
        }
      }
      await applyAsProvider(account);
      await showOutcome({ ok: true, title: "Your provider account was created successfully", text: "We received your application. Our team will review it and email you. You can follow the status on your provider page." });
      afterDone();
    } catch (err) {
      btn.disabled = false; btn.textContent = label;
      showMessage(msg, err.message);
      showOutcome({ ok: false, title: "Sorry, we could not finish your application", text: `${friendlyMessage(err.message)} Your answers are still on this page, so you can fix it and press the button again.` });
    }
  });
}
