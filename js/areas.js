import { esc } from "./app.js";

// Same rules as the database (set_service_areas): a 5-digit ZIP or a city name.
export const MAX_AREAS = 30;

// "  irving, tx " -> {kind:"city", label:"Irving"}   "75038" -> {kind:"zip", label:"75038"}   junk -> null
export function parseArea(text) {
  let t = String(text ?? "").trim().replace(/\s+/g, " ").replace(/,\s*(tx|texas)$/i, "");
  if (/^[0-9]{5}$/.test(t)) return { kind: "zip", label: t };
  if (/^[A-Za-z][A-Za-z .'-]{1,59}$/.test(t)) {
    // all-lower or ALL-CAPS typing is tidied ("irving" -> "Irving"); mixed case like "McKinney" is kept as typed
    const tidy = t === t.toLowerCase() || t === t.toUpperCase();
    return { kind: "city", label: tidy ? t.toLowerCase().replace(/(^|[ .'-])([a-z])/g, (_, a, b) => a + b.toUpperCase()) : t };
  }
  return null;
}

// Chips + one input. Returns { get() -> array of labels }.
export function mountAreaEditor(box, initial = [], { onChange } = {}) {
  let areas = [...new Set(initial)];
  box.innerHTML = `
    <div class="chips" data-chips></div>
    <div class="area-add">
      <input data-area-input placeholder="Add a city or ZIP code, e.g. Irving or 75038" maxlength="60" aria-label="Add a city or ZIP code" list="area-suggestions">
      <button type="button" class="btn btn-sm btn-outline" data-area-add>Add</button>
    </div>
    <div class="hint" data-area-msg>Press Enter or Add. Customers searching these places will find you.</div>`;
  const chips = box.querySelector("[data-chips]"), input = box.querySelector("[data-area-input]"), msg = box.querySelector("[data-area-msg]");

  const draw = () => {
    chips.innerHTML = areas.length
      ? areas.map((a) => `<span class="chip">${esc(a)}<button type="button" data-remove="${esc(a)}" aria-label="Remove ${esc(a)}">×</button></span>`).join("")
      : `<span class="muted small">No areas yet.</span>`;
    onChange?.(areas);
  };
  const say = (t, bad) => { msg.textContent = t; msg.classList.toggle("bad", !!bad); };

  const add = () => {
    // allow several at once: "Irving, 75038, Dallas"
    const parts = input.value.split(/[;\n]|,(?!\s*(?:tx|texas)\b)/i).map((x) => x.trim()).filter(Boolean);
    if (!parts.length) return;
    for (const part of parts) {
      const a = parseArea(part);
      if (!a) return say(`“${part.slice(0, 30)}” is not a city name or a 5-digit ZIP code.`, true);
      if (areas.some((x) => x.toLowerCase() === a.label.toLowerCase())) continue;
      if (areas.length >= MAX_AREAS) return say(`You can list at most ${MAX_AREAS} areas.`, true);
      areas.push(a.label);
    }
    input.value = "";
    say("Added.");
    draw();
  };
  box.querySelector("[data-area-add]").addEventListener("click", add);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); add(); } });
  chips.addEventListener("click", (e) => {
    const b = e.target.closest("[data-remove]");
    if (!b) return;
    areas = areas.filter((x) => x !== b.dataset.remove);
    say("Removed.");
    draw();
  });
  draw();
  return {
    get: () => [...areas],
    // text typed but not added yet counts too, so nobody loses it by pressing Save
    flush: () => { if (input.value.trim()) add(); return !input.value.trim(); },
  };
}
