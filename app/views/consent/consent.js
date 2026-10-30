// Consent banner and Google Ads conversion measurement (docs/Consent.md).
//
// ConsentController wraps this file in a function that receives `config`
// ({ id: "AW-…", conversions: { name: "AW-…/label" } }). It is served only
// when a conversion ID is configured.
//
// Google Consent Mode v2, "basic": nothing is requested from Google before
// the visitor accepts. After acceptance only the Google Ads tag is loaded. It
// is not configured for the conversion ID (no config command), so it reports
// no page views and keeps no click identifier across pages; it sends
// something only when a conversion takes place, without ad personalisation.
// No analytics, no remarketing. The choice is kept in
// localStorage for at most twelve months and can be changed at any time
// through an element with the attribute data-consent-settings (the
// "Cookie settings" link in the footer).
"use strict";

var STORAGE_KEY = "oyd-consent";
var STORAGE_VERSION = 1;
var MAX_AGE_MS = 365 * 24 * 60 * 60 * 1000;
var GOOGLE_COOKIE = /^(_gcl_|_gac_)/;
var TAG_URL = "https://www.googletagmanager.com/gtag/js?id=";

var tagLoaded = false;
var banner = null;

function readChoice() {
  try {
    var raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    var stored = JSON.parse(raw);
    if (!stored || stored.v !== STORAGE_VERSION || typeof stored.ads !== "boolean") return null;
    var at = Date.parse(stored.at);
    if (!(at > 0) || Date.now() - at > MAX_AGE_MS) return null;
    return stored.ads;
  } catch (e) {
    return null;
  }
}

function storeChoice(ads) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ v: STORAGE_VERSION, ads: ads, at: new Date().toISOString() }));
  } catch (e) {
    // Without storage the banner simply comes back on the next page.
  }
}

function gtag() {
  window.dataLayer.push(arguments);
}

function loadTag() {
  if (tagLoaded) return;
  tagLoaded = true;
  window.dataLayer = window.dataLayer || [];
  window.gtag = gtag;
  gtag("consent", "default", {
    ad_storage: "denied",
    ad_user_data: "denied",
    ad_personalization: "denied",
    analytics_storage: "denied"
  });
  gtag("consent", "update", { ad_storage: "granted", ad_user_data: "granted" });
  gtag("set", { allow_ad_personalization_signals: false });
  gtag("js", new Date());
  var script = document.createElement("script");
  script.async = true;
  script.src = TAG_URL + encodeURIComponent(config.id);
  document.head.appendChild(script);
}

function convert(name) {
  var target = config.conversions[name];
  if (!tagLoaded || !target) return false;
  gtag("event", "conversion", { send_to: target, transport_type: "beacon" });
  return true;
}

// A page that is itself the end of a conversion (the confirmation of a
// newsletter subscription) names it in <meta name="oyd-conversion">.
function convertPage() {
  var meta = document.querySelector('meta[name="oyd-conversion"]');
  if (meta) convert(meta.getAttribute("content"));
}

// Which conversion a link stands for: data-conversion if it has one
// ("none" for none), otherwise by its target.
function conversionFor(link) {
  var named = link.getAttribute("data-conversion");
  if (named !== null) return named;
  var url;
  try {
    url = new URL(link.getAttribute("href"), window.location.href);
  } catch (e) {
    return null;
  }
  if (url.hostname === "hub.docker.com" && url.pathname.indexOf("/r/oydeu/dpp-manager") === 0) return "get_started";
  if (url.origin === window.location.origin && url.pathname === "/kb/getting-started/") return "get_started";
  if (url.hostname === "github.com" && /^\/OwnYourData\/[^/]+/.test(url.pathname)) return "github";
  return null;
}

function onLinkActivated(event) {
  if (event.type === "auxclick" && event.button !== 1) return;
  var link = event.target && event.target.closest ? event.target.closest("a[href]") : null;
  if (!link) return;
  var name = conversionFor(link);
  if (name) convert(name);
}

function deleteGoogleCookies() {
  var labels = window.location.hostname.split(".");
  document.cookie.split(";").forEach(function (pair) {
    var name = pair.split("=")[0].trim();
    if (!GOOGLE_COOKIE.test(name)) return;
    document.cookie = name + "=; Max-Age=0; path=/";
    for (var i = 0; i < labels.length - 1; i++) {
      document.cookie = name + "=; Max-Age=0; path=/; domain=." + labels.slice(i).join(".");
    }
  });
}

function choose(ads) {
  storeChoice(ads);
  hideBanner();
  if (ads) {
    loadTag();
    convertPage();
    return;
  }
  deleteGoogleCookies();
  if (tagLoaded) {
    gtag("consent", "update", { ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" });
    window.location.reload();
  }
}

var STYLE = [
  ".oyd-consent{position:fixed;left:0;right:0;bottom:0;z-index:2147483000;padding:0 12px 12px;pointer-events:none}",
  ".oyd-consent[hidden]{display:none}",
  ".oyd-consent .oc-box{pointer-events:auto;max-width:920px;margin:0 auto;background:var(--surface,#fff);color:var(--text,#1d2327);",
  "border:1px solid var(--line,#e2e5e8);border-radius:12px;box-shadow:0 6px 24px rgba(0,0,0,.18);padding:18px 20px;",
  "font:15px/1.5 system-ui,-apple-system,\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif}",
  ".oyd-consent h2{font-size:16px;margin:0 0 6px}",
  ".oyd-consent p{margin:0 0 12px;color:var(--muted,#5b6770)}",
  ".oyd-consent a{color:var(--accent,#0b6e4f)}",
  ".oyd-consent .oc-actions{display:flex;gap:12px;flex-wrap:wrap}",
  ".oyd-consent button{flex:1 1 160px;max-width:240px;padding:10px 18px;border-radius:8px;font-family:inherit;font-size:15px;font-weight:600;line-height:1.2;cursor:pointer;",
  "border:1px solid var(--accent,#0b6e4f);background:var(--accent,#0b6e4f);color:var(--surface,#fff)}",
  ".oyd-consent button:focus-visible{outline:2px solid var(--text,#1d2327);outline-offset:2px}",
  ".oyd-consent .oc-current{font-size:13px;margin:-4px 0 12px}"
].join("");

function hideBanner() {
  if (banner) banner.hidden = true;
}

function showBanner(focus) {
  if (!banner) {
    var style = document.createElement("style");
    style.textContent = STYLE;
    document.head.appendChild(style);
    banner = document.createElement("section");
    banner.className = "oyd-consent";
    banner.setAttribute("aria-labelledby", "oyd-consent-title");
    banner.innerHTML =
      '<div class="oc-box">' +
      '<h2 id="oyd-consent-title">Measuring our ads</h2>' +
      "<p>OwnYourData advertises these free tools with Google Ads. With your consent, Google’s conversion tag tells us " +
      "when a visit from one of our ads leads to “Getting started” or to one of our GitHub repositories. " +
      "Google then sets cookies and receives your IP address and browser details, possibly in the USA. " +
      "No analytics, no remarketing. Without your consent nothing is loaded from Google. " +
      "You can change your choice at any time under “Cookie settings” at the bottom of the page. " +
      '<a href="/privacy#conversion-tracking">Privacy policy</a></p>' +
      '<p class="oc-current" hidden></p>' +
      '<div class="oc-actions">' +
      '<button type="button" data-choice="decline">Decline</button>' +
      '<button type="button" data-choice="accept">Accept</button>' +
      "</div></div>";
    banner.addEventListener("click", function (event) {
      var button = event.target.closest ? event.target.closest("button[data-choice]") : null;
      if (button) choose(button.getAttribute("data-choice") === "accept");
    });
    document.body.appendChild(banner);
  }
  var current = banner.querySelector(".oc-current");
  var choice = readChoice();
  current.hidden = choice === null;
  current.textContent = choice === true ? "Your current choice: accepted." : choice === false ? "Your current choice: declined." : "";
  banner.hidden = false;
  if (focus) banner.querySelector("button").focus();
}

function init() {
  var settings = document.querySelectorAll("[data-consent-settings]");
  for (var i = 0; i < settings.length; i++) {
    settings[i].hidden = false;
    settings[i].addEventListener("click", function (event) {
      event.preventDefault();
      showBanner(true);
    });
  }
  document.addEventListener("click", onLinkActivated, true);
  document.addEventListener("auxclick", onLinkActivated, true);

  var choice = readChoice();
  if (choice === true) {
    loadTag();
    convertPage();
  } else if (choice === null) {
    showBanner(false);
  }
}

window.oydConsent = { open: function () { showBanner(true); }, convert: convert };

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
