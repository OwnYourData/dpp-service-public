# Consent banner and conversion measurement

The start page can measure, with the visitor's consent, whether a visit that
started with a Google Ads advertisement leads to one of a few actions. Without
configuration the feature is off: no banner, no script, no request to Google.

## Configuration

| Variable | Value |
|---|---|
| `GOOGLE_ADS_ID` | Conversion ID of the Google Ads account, `AW-` followed by digits. Without a valid value nothing below applies. |
| `GOOGLE_ADS_LABEL_GET_STARTED` | Conversion label: a click on “Getting started” (`/kb/getting-started/`) or on the DPP Manager image on Docker Hub. |
| `GOOGLE_ADS_LABEL_GITHUB` | Conversion label: a click on a repository under `github.com/OwnYourData/`. |
| `GOOGLE_ADS_LABEL_NEWSLETTER` | Conversion label: a confirmed newsletter subscription. |

A label is the part of the conversion's `send_to` after the slash
(`AW-…/<label>`); the service puts ID and label together. A conversion whose
label is missing or malformed is not measured; the others still are. No user
data (such as an email address) is passed to Google: enhanced conversions are
not used.

## Behaviour

- With `GOOGLE_ADS_ID` set, the start page and `/privacy` embed `/consent.js`.
  Other pages on the same host (the Knowledge Base) can embed it as well; while
  no ID is configured it is an empty script.
- Before the visitor decides, the page loads nothing from Google. The banner
  offers “Decline” and “Accept”, in the same style.
- After “Accept”, the script sets Google Consent Mode v2 (all signals denied by
  default, then `ad_storage` and `ad_user_data` granted, `ad_personalization`
  and `analytics_storage` left denied), switches ad personalisation signals off
  and loads `gtag.js` for the conversion ID. The tag is not configured for the
  ID (no `gtag("config")`): it reports no page views, sets no cookies on
  Google's domains for the click identifier and sends something only when a
  conversion takes place. No Google Analytics, no remarketing. A conversion is
  therefore attributed to an ad when it happens on the page the ad led to,
  whose address carries the click identifier.
- Conversions are sent for links by their target (see the table) or by a
  `data-conversion` attribute on the link (`none` for none). A page that is
  itself the end of a conversion names it in
  `<meta name="oyd-conversion" content="…">`.
- The choice is kept in `localStorage` (`oyd-consent`) for twelve months. An
  element with the attribute `data-consent-settings` (the “Cookie settings”
  link in the footer) opens the banner again. Declining after accepting deletes
  the `_gcl_` cookies on the page's domain and reloads the page without the
  tag.

## Checking it

`spec/requests/consent_spec.rb` checks the server side: without an ID no
script and no banner; with an ID, no Google address in any page before the
script runs. `script/consent_check.mjs` checks a running instance in a browser
(Playwright): no request to a Google domain before consent, and the tag after
“Accept”.
