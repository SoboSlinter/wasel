import { renderChrome, getSettings, pct, dollars } from "./app.js";
await renderChrome();

// The fee and Pro price on these pages come from the admin's settings (the text in the HTML is the fallback).
const s = await getSettings();
const values = {
  free_fee: pct(s.free_fee_percent), pro_fee: pct(s.pro_fee_percent),
  free_keep: pct(100 - Number(s.free_fee_percent)), pro_keep: pct(100 - Number(s.pro_fee_percent)),
  pro_price: dollars(s.pro_price_cents),
};
document.querySelectorAll("[data-setting]").forEach((el) => { if (values[el.dataset.setting]) el.textContent = values[el.dataset.setting]; });
