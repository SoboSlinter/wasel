import { sb, renderChrome, showMessage, friendlyMessage, kickEmails, loadSiteContacts, contactLink, esc } from "./app.js";

const user = await renderChrome();
const form = document.getElementById("contact-form");
const msg = document.getElementById("c-msgbox");
const send = document.getElementById("c-send");
const count = document.getElementById("c-count");

// signed-in people do not need to retype who they are
if (user) {
  form.email.value = user.email ?? "";
  const { data } = await sb.from("profiles").select("full_name").eq("id", user.id).maybeSingle();
  if (data?.full_name) form.name.value = data.full_name;
}
form.message.addEventListener("input", () => { count.textContent = form.message.value.length; });

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  showMessage(msg, "");
  if (form.website.value) return;                       // hidden trap field: only bots fill it in
  const name = form.name.value.trim(), email = form.email.value.trim(), text = form.message.value.trim();
  if (!name) return showMessage(msg, "Please enter your name.");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return showMessage(msg, "Please enter a valid email address.");
  if (text.length < 10) return showMessage(msg, "Please write at least 10 characters.");
  send.disabled = true; send.textContent = "Sending…";
  const { error } = await sb.rpc("submit_contact", { p_name: name, p_email: email, p_topic: form.topic.value, p_message: text });
  if (error) {
    send.disabled = false; send.textContent = "Send message";
    return showMessage(msg, friendlyMessage(error.message));
  }
  kickEmails(); // tells the admins now if you are signed in; otherwise the every-minute job does it
  form.reset(); count.textContent = "0";
  form.hidden = true;
  const done = document.createElement("div");
  done.className = "panel contact-done"; done.setAttribute("role", "status");
  done.innerHTML = `<h2 style="margin:0 0 8px">Thank you!</h2><p>We got your message and will reply by email to <strong></strong>.</p><p><a class="link" href="index.html">Back to home</a></p>`;
  done.querySelector("strong").textContent = email;
  form.after(done);
});

// "Reach us directly": the details the main admin keeps up to date
const reach = await loadSiteContacts();
if (reach.length) {
  document.getElementById("reach-box").hidden = false;
  document.getElementById("reach-list").innerHTML = reach.map((x) => `<li><strong>${esc(x.label)}</strong><br>${contactLink(x)}</li>`).join("");
}
