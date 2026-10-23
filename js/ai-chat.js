// Help assistant: a chat button in the corner for visitors and customers.
// Questions go to the ai-chat Edge Function, which answers through OmniRoute (see supabase/functions/ai-chat).
import { sb, esc, friendlyMessage } from "./app.js";
import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";

const STORE = "wasel-ai-chat";
const WELCOME = "Hi! I can help you find a service or answer questions about booking on Wasel.";

let history = [];
try { history = JSON.parse(sessionStorage.getItem(STORE) || "[]"); } catch { /* storage blocked: start empty */ }
const save = () => { try { sessionStorage.setItem(STORE, JSON.stringify(history.slice(-20))); } catch { /* ignore */ } };

async function ask(messages) {
  const { data: { session } } = await sb.auth.getSession();
  const headers = { "content-type": "application/json", apikey: SUPABASE_KEY };
  if (session) headers.authorization = `Bearer ${session.access_token}`;
  let res;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/ai-chat`, {
      method: "POST", headers, body: JSON.stringify({ messages, lang: window.waselLang }),
    });
  } catch (e) { throw new Error(friendlyMessage(e.message)); }
  const out = await res.json().catch(() => ({}));
  if (res.status === 404 && !out.error) throw new Error("The assistant is not set up yet.");
  if (!res.ok || !out.reply) throw new Error(out.error || "Something went wrong. Try again.");
  return out.reply;
}

export function mountAiChat() {
  if (document.getElementById("ai-chat")) return;
  const root = document.createElement("div");
  root.id = "ai-chat";
  root.className = "aichat";
  root.innerHTML = `
    <button type="button" class="aichat-fab" aria-expanded="false" aria-controls="ai-chat-panel">
      <span aria-hidden="true">💬</span><span>Ask Wasel</span>
    </button>
    <section class="aichat-panel" id="ai-chat-panel" role="dialog" aria-label="Wasel assistant" hidden>
      <header class="aichat-head">
        <strong>Wasel assistant</strong>
        <button type="button" class="icon-btn aichat-close" aria-label="Close chat">✕</button>
      </header>
      <div class="aichat-list" aria-live="polite"></div>
      <form class="aichat-form">
        <input name="q" type="text" maxlength="1000" autocomplete="off" placeholder="Type your question" aria-label="Your question" required>
        <button class="btn btn-sm" type="submit">Send</button>
      </form>
      <p class="aichat-note">Answers are written by AI and can be wrong.</p>
    </section>`;
  document.body.append(root);

  const fab = root.querySelector(".aichat-fab");
  const panel = root.querySelector(".aichat-panel");
  const list = root.querySelector(".aichat-list");
  const form = root.querySelector(".aichat-form");
  const input = form.q;

  // Text from people and from the AI is never translated (data-no-i18n) and always escaped.
  const bubble = (role, text, extra = "") =>
    `<div class="chat-msg ${role === "user" ? "mine" : "theirs"} ${extra}"><div class="chat-body" data-no-i18n>${esc(text)}</div></div>`;
  const render = () => {
    list.innerHTML = `<div class="chat-msg theirs"><div class="chat-body">${esc(WELCOME)}</div></div>` +
      history.map((m) => bubble(m.role, m.content)).join("");
    list.scrollTop = list.scrollHeight;
  };

  const open = (yes) => {
    panel.hidden = !yes;
    fab.setAttribute("aria-expanded", String(yes));
    if (yes) { render(); input.focus(); }
  };
  fab.addEventListener("click", () => open(panel.hidden));
  root.querySelector(".aichat-close").addEventListener("click", () => { open(false); fab.focus(); });
  root.addEventListener("keydown", (e) => { if (e.key === "Escape" && !panel.hidden) { open(false); fab.focus(); } });

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const q = input.value.trim();
    if (!q || form.dataset.busy) return;
    form.dataset.busy = "1";
    input.value = "";
    history.push({ role: "user", content: q });
    save();
    render();
    list.insertAdjacentHTML("beforeend", `<div class="chat-msg theirs aichat-typing"><div class="chat-body">Typing…</div></div>`);
    list.scrollTop = list.scrollHeight;
    try {
      const reply = await ask(history.slice(-12));
      history.push({ role: "assistant", content: reply });
      save();
      render();
    } catch (err) {
      history.pop(); // let the person send the same question again
      save();
      render();
      input.value = q;
      list.insertAdjacentHTML("beforeend", `<div class="alert alert-error" role="alert">${esc(err.message)}</div>`);
      list.scrollTop = list.scrollHeight;
    } finally {
      delete form.dataset.busy;
      input.focus();
    }
  });
}
