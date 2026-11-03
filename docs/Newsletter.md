# Newsletter: notifications about new Delegated Acts

The start page offers a subscription to short notifications about new
Delegated Acts for Digital Product Passports. Without mail configuration the
feature is off: no form, and every `/newsletter` path answers 404.

## Configuration

| Variable | Value |
|---|---|
| `MS_GRAPH_TENANT_ID` | Directory (tenant) ID of the Microsoft 365 tenant. |
| `MS_GRAPH_CLIENT_ID` | Application (client) ID of the app that sends. |
| `MS_GRAPH_CLIENT_SECRET` | Client secret of that app (keep it in a secret, not in the configuration). |
| `NEWSLETTER_FROM` | The mailbox that sends, e.g. `newsletter@example.org`. |

Mail goes out through Microsoft Graph (`sendMail`) with an app-only token
(OAuth 2.0 client credentials), as plain text. Confirmation mails go as JSON,
without a copy in Sent Items. Notifications carry headers of their own for
unsubscribing with one click, which Graph accepts only in MIME format; Graph
keeps a copy of each of them in Sent Items of the sending mailbox. The app
needs no API permission in Entra; restrict it to the one mailbox with Exchange
Online RBAC for Applications: a service principal, a management scope for that
mailbox and the role `Application Mail.Send` with that scope. `Test-ServicePrincipalAuthorization` shows the result.

## Behaviour

- **Sign-up** (`POST /newsletter`, email and language `en` or `de`): the page
  always says "check your inbox", whether the address is new, waiting or
  already confirmed, so that the form does not reveal who subscribed. A new
  confirmation mail for the same address goes out at most every ten minutes;
  one network may sign up five times an hour; a hidden field catches simple
  bots.
- **Double opt-in:** the mail carries a link that is valid for seven days. It
  leads to a page with a button; only pressing it (`POST`) confirms, so that
  mail scanners that open links confirm nothing. Unconfirmed subscriptions are
  deleted after seven days (on each sign-up, and with `newsletter:prune`).
- **Stored:** the address, the language, and when the subscription was
  requested and confirmed. Nothing else; links carry signed ids, no token is
  stored.
- **Unsubscribing:** every notification carries a link to a page with a button;
  pressing it deletes the row at once. The same address is in the headers
  `List-Unsubscribe` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`
  (RFC 2369, RFC 8058), so that a mail program can offer "Unsubscribe": it
  sends a `POST` to that address, which unsubscribes without a page and answers
  with a short text. Exchange Online passes `List-Unsubscribe` on but drops
  `List-Unsubscribe-Post`; a mail program then opens the address in the
  browser, which shows the page with the button.
- **Conversion:** the page after confirming names the conversion `newsletter`
  (docs/Consent.md); it counts only with the visitor's consent.

## Sending a notification

The text comes on standard input; the first line is the subject (a leading
`# ` is dropped), the rest the body. Without `SEND=1` the task only shows the
mail and how many subscribers would receive it. It sends one message every
2.1 seconds (Exchange Online accepts 30 a minute from one mailbox) and prints
no address.

```
bin/rails newsletter:stats
bin/rails newsletter:send LOCALE=en < issue-en.md
bin/rails newsletter:send LOCALE=en SEND=1 < issue-en.md
```

## Removing unconfirmed subscriptions

`bin/rails newsletter:prune` deletes the subscriptions that were not
confirmed within seven days and prints how many. Run it once a day, for
example as a cron job; it touches nothing else.
