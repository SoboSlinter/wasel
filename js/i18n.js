// Language support: English (default) and Spanish.
// Pages are written in English. When Spanish is chosen, every piece of visible text
// (including text the scripts add later) is looked up in js/i18n-es.js and swapped.
// Text with no entry stays in English, so a missing translation never breaks a page.
// Names, descriptions and other text people typed are never in the dictionary, so they stay as written.
(function () {
  var COLLECT = false; // development only: reports the text it sees so the dictionary can be completed
  var KEY = "wasel-lang";
  var lang = "en", explicit = false;
  try {
    var saved = localStorage.getItem(KEY);
    explicit = saved === "es" || saved === "en";
    lang = explicit ? saved : ((navigator.language || "").toLowerCase().indexOf("es") === 0 ? "es" : "en");
  } catch (e) { /* storage blocked: follow the browser language */ }
  document.documentElement.lang = lang;

  var ES = (window.WASEL_ES || {});
  var exact = ES.exact || {};
  var patterns = (ES.patterns || []).map(function (p) { return [new RegExp("^" + p[0] + "$", "u"), p[1]]; });
  var seen = {};

  function norm(s) { return s.replace(/\s+/g, " ").trim(); }

  function lookup(core) {
    if (Object.prototype.hasOwnProperty.call(exact, core)) return exact[core];
    for (var i = 0; i < patterns.length; i++) {
      var m = core.match(patterns[i][0]);
      if (m) return core.replace(patterns[i][0], patterns[i][1]);
    }
    return null;
  }
  function report(core) {
    if (!COLLECT || seen[core] || !/[A-Za-z]{2}/.test(core)) return;
    seen[core] = 1;
    try { fetch("http://localhost:3012/", { method: "POST", mode: "no-cors", body: core }); } catch (e) { /* ignore */ }
  }
  function tr(raw) {
    var core = norm(raw);
    if (!core) return raw;
    if (lang !== "es") { if (COLLECT && lookup(core) === null) report(core); return raw; }
    var out = lookup(core);
    if (out === null) { report(core); return raw; }
    var lead = raw.match(/^\s*/)[0], trail = raw.match(/\s*$/)[0];
    return lead + out + trail;
  }

  var ATTRS = ["placeholder", "aria-label", "title", "alt"];
  function skip(el) {
    return !el || el.closest && el.closest("script,style,code,pre,textarea,[data-no-i18n],[contenteditable=true]");
  }
  function doText(node) {
    if (skip(node.parentElement)) return;
    var v = node.nodeValue;
    if (!v || !v.trim()) return;
    var t = tr(v);
    if (t !== v) node.nodeValue = t;
  }
  function doEl(el) {
    if (el.nodeType !== 1 || skip(el)) return;
    for (var i = 0; i < ATTRS.length; i++) {
      var a = el.getAttribute(ATTRS[i]);
      if (a) { var t = tr(a); if (t !== a) el.setAttribute(ATTRS[i], t); }
    }
    if (el.tagName === "INPUT" && (el.type === "submit" || el.type === "button") && el.value) {
      var tv = tr(el.value); if (tv !== el.value) el.value = tv;
    }
  }
  function walk(root) {
    if (root.nodeType === 3) { doText(root); return; }
    if (root.nodeType !== 1) return;
    doEl(root);
    var w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    var n;
    while ((n = w.nextNode())) { if (n.nodeType === 3) doText(n); else doEl(n); }
  }

  function start() {
    if (document.title) { var t = tr(document.title); if (t !== document.title) document.title = t; }
    walk(document.body);
    new MutationObserver(function (list) {
      for (var i = 0; i < list.length; i++) {
        var m = list[i];
        if (m.type === "childList") { for (var j = 0; j < m.addedNodes.length; j++) walk(m.addedNodes[j]); }
        else if (m.type === "characterData") doText(m.target);
        else if (m.type === "attributes") doEl(m.target);
      }
    }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }
  var tt = document.querySelector("title");
  if (tt) new MutationObserver(function () { var t = tr(document.title); if (t !== document.title) document.title = t; }).observe(tt, { childList: true, characterData: true, subtree: true });
  if (document.body) start(); else document.addEventListener("DOMContentLoaded", start);

  // Language button in the footer (data-lang-toggle).
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-lang-toggle]");
    if (!b) return;
    try { localStorage.setItem(KEY, lang === "es" ? "en" : "es"); } catch (err) { /* ignore */ }
    location.reload();
  });

  window.waselLang = lang;
  window.waselLangExplicit = explicit;
  window.waselLocale = lang === "es" ? "es-US" : "en-US";
  window.waselT = function (s) { return tr(s); };
})();
