// Browser check of the consent banner (docs/Consent.md), with Playwright.
//
//   node spec/browser/consent_check.mjs <base URL> [--live]
//
// The instance must have GOOGLE_ADS_ID set. Without --live, requests to Google
// are recorded and then blocked, so the check never reaches Google; with
// --live they go through (for a check of the deployed instance).
//
// Checks, in a fresh browser profile:
//  1. Before any choice, the start page, the privacy policy, the API
//     documentation and the Knowledge Base send no request to a Google domain,
//     and the start page shows the banner with Decline and Accept alike.
//  2. After Decline: still no request to Google, also after a reload.
//  3. "Cookie settings" opens the banner again; after Accept the tag is
//     requested, with ad personalisation and analytics denied, and is not
//     configured for the ID (with --live: no page view reaches Google).
//  4. A click on a GitHub repository and on "Getting started" sends the
//     configured conversions.
//  5. Declining again reloads the page without the tag and deletes the _gcl_
//     cookies.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const base = (process.argv[2] || "http://localhost:3000").replace(/\/$/, "");
const live = process.argv.includes("--live");
const GOOGLE = /(^|\.)(google(-analytics|adservices|apis|syndication|tagmanager|usercontent)?|gstatic|doubleclick)\.[a-z.]+$/i;

let failures = 0;
function check(ok, what) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${what}`);
  if (!ok) failures += 1;
}

const browser = await chromium.launch();
const context = await browser.newContext();
const google = [];
await context.route("**/*", (route) => {
  const url = new URL(route.request().url());
  if (GOOGLE.test(url.hostname)) {
    google.push(url.href);
    return live ? route.continue() : route.abort();
  }
  return route.continue();
});
const page = await context.newPage();
const dataLayer = () => page.evaluate(() => (window.dataLayer || []).map((entry) => Array.from(entry)));

// 1. Nothing before a choice.
for (const path of ["/", "/privacy", "/api-docs/index.html", "/kb/"]) {
  const response = await page.goto(base + path, { waitUntil: "networkidle" });
  if (path === "/kb/" && response && response.status() === 404) {
    console.log("SKIP  /kb/ is not served by this instance");
    continue;
  }
  check(google.length === 0, `no request to Google before a choice on ${path}`);
}
await page.goto(base + "/", { waitUntil: "networkidle" });
const banner = page.locator(".oyd-consent");
check(await banner.isVisible(), "the banner is shown before a choice");
const styles = await page.$$eval(".oyd-consent button", (buttons) =>
  buttons.map((b) => {
    const s = getComputedStyle(b);
    return { text: b.textContent, look: [s.backgroundColor, s.color, s.fontSize, s.fontWeight, s.borderColor, s.padding].join("|"), width: b.offsetWidth, height: b.offsetHeight };
  })
);
check(styles.map((s) => s.text).join(",") === "Decline,Accept", "the banner offers Decline and Accept");
check(styles.length === 2 && styles[0].look === styles[1].look && styles[0].height === styles[1].height && Math.abs(styles[0].width - styles[1].width) <= 2,
  "Decline and Accept look alike");
check(await page.locator("footer [data-consent-settings]").isVisible(), "the footer offers the cookie settings");

// 2. Decline.
await page.click('.oyd-consent button[data-choice="decline"]');
check(!(await banner.isVisible()), "the banner closes after Decline");
await page.reload({ waitUntil: "networkidle" });
check(!(await banner.isVisible()), "the banner stays closed after a reload");
check(google.length === 0, "no request to Google after Decline");

// 3. Accept through the cookie settings.
await page.click("footer [data-consent-settings]");
check(await banner.isVisible(), "Cookie settings opens the banner again");
check((await page.locator(".oyd-consent .oc-current").textContent()) === "Your current choice: declined.", "the banner names the current choice");
await page.click('.oyd-consent button[data-choice="accept"]');
await page.waitForTimeout(1000);
const tag = google.filter((url) => url.startsWith("https://www.googletagmanager.com/gtag/js?id=AW-"));
check(tag.length === 1, `the tag is requested after Accept (${tag[0] || "none"})`);
const layer = await dataLayer();
const consentDefault = layer.find((e) => e[0] === "consent" && e[1] === "default");
const consentUpdate = layer.find((e) => e[0] === "consent" && e[1] === "update");
const config = layer.find((e) => e[0] === "config");
const set = layer.find((e) => e[0] === "set");
check(consentDefault && Object.values(consentDefault[2]).every((v) => v === "denied"), "consent default: everything denied");
check(consentUpdate && JSON.stringify(consentUpdate[2]) === JSON.stringify({ ad_storage: "granted", ad_user_data: "granted" }),
  "consent update: only ad_storage and ad_user_data granted");
check(!config, "the tag is not configured for the ID, so it reports no page views");
check(set && set[1].allow_ad_personalization_signals === false, "ad personalisation signals are switched off");
if (live) {
  await page.waitForTimeout(3000);
  const pageViews = google.filter((url) => /[?&]en=page_view\b/.test(url) || url.includes("/ccm/collect"));
  check(pageViews.length === 0, `no page view is sent to Google${pageViews.length ? ` (${pageViews[0]})` : ""}`);
}

// 4. Conversions; navigation is held back so that the page stays.
await page.evaluate(() => document.addEventListener("click", (e) => e.preventDefault()));
await page.click('ul.repos a[href="https://github.com/OwnYourData/dpplint"]');
await page.click('article h3 a[href="/kb/getting-started/"]');
const conversions = (await dataLayer()).filter((e) => e[0] === "event" && e[1] === "conversion").map((e) => e[2].send_to);
console.log(`      conversions sent: ${conversions.join(", ") || "none"}`);
check(conversions.length === 2 && conversions.every((target) => /^AW-\d+\/[A-Za-z0-9_-]+$/.test(target)) && conversions[0] !== conversions[1],
  "a click on a GitHub repository and on Getting started each sends its conversion");

// 5. Withdraw.
await page.evaluate(() => { document.cookie = "_gcl_au=test; path=/"; });
const before = google.length;
await page.click("footer [data-consent-settings]");
await Promise.all([page.waitForEvent("load"), page.click('.oyd-consent button[data-choice="decline"]')]);
await page.waitForLoadState("networkidle");
check(google.length === before, "after withdrawing, the reloaded page sends no request to Google");
check(!(await page.evaluate(() => document.cookie)).includes("_gcl_"), "after withdrawing, the _gcl_ cookies are gone");

await browser.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
