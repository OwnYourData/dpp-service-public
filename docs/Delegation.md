# Delegation without a shared secret

**Status:** Implemented and in production. `X-DPP-Storage` carries a
delegation signed by the economic operator; no `client_secret` is stored or
accepted.


---

## 1. Why

The obvious way to let the DPP Service write into a pod is for the economic
operator to hand it a storage JWT containing `client_id` and `client_secret`.
That is not an access token, it is the credentials themselves. Five problems
follow from this:

1. **Unlimited power of attorney.** Access tokens expire after two hours, the
   `client_secret` never does. Revocation means: delete the OAuth application
   at the intermediary — manually, all-or-nothing, outside the system.
2. **No purpose limitation.** The mandate reads "read/write on collection X",
   not "store exactly this passport". It applies to all objects of the
   collection and to all future write operations.
3. **Transit through a foreign stack.** A JWT is Base64, not encryption.
   The header potentially ends up in access logs, proxy logs, traces,
   error trackers and shell history.
4. **Credential hoarding.** The DPP Service has to store the credentials
   permanently and thereby becomes the repository of the pod credentials of
   all economic operators, protected by a single `KEY_VAULT_KEK`.
5. **Confused deputy.** Every write operation appears in the pod's event log as
   an action of the holder, regardless of whether they initiated it. The log
   proves *that*, not *who authorized it*.

On top of that: a storage JWT built with `alg: none` is no proof at all.
Whoever intercepts one can have data written into someone else's pod.

**The actual design flaw:** the holder already has a signing key and uses it in
the same call to sign their bearer token for the DPP Service. Handing over a
password as well would mean public-key cryptography on one side of the request
and a shared secret on the other.

## 2. Target picture

Three signed statements, one key model, **no secret anywhere**:

| Statement | issued by | addressed to | Purpose |
|---|---|---|---|
| **Delegation Assertion** | economic operator | pod | "This service may store this passport in this collection" |
| **Client Assertion** | DPP Service | pod (token endpoint) | "I am the service that the delegation names" |
| **DPoP Proof** | DPP Service | pod (every request) | "I hold the key this token is bound to" |

Standards: RFC 7523 (JWT as a grant *and* as client authentication), RFC 9449
(DPoP), RFC 8725 (JWT best practices, in particular the `typ` header), RFC 7009
(revocation). All within what EN 18239:2026 provides for: OAuth 2.0 with JWT
bearer tokens.

## 3. Keys and identities — do not confuse them

| What | Who holds the private key | What for |
|---|---|---|
| **Identity DID of the economic operator** | the economic operator | write token to the DPP Service, **delegation assertion**, owner binding |
| **Passport DID** (one per DPP) | Variant A: the DPP Service; Variant B: the holder or the secure element | identifier of the passport, commitment of the payload hash (see `Integrity.md`) |
| **Service DID of the DPP Service** | the DPP Service | client assertion, DPoP |
| **Reader DID of the DPP Service** (one per pod) | the DPP Service | its identity as the protected statutory reader of a DPP hosting collection at that pod |

The delegation is signed with the **identity DID**, not with the passport DID.
At `CreateDPP` the passport DID does not even exist yet in variant A.

The reader DIDs are separate from the service DID and from each other: the
reader of a staging pod is not the reader of a production pod. The intermediary
enters the reader DID of its pod as a fixed value when a DPP hosting contract is
signed. Each reader belongs to exactly one pod, identified by the pod's base
URL. Configuration, per reader `<NAME>`:

| Variable | Content |
|---|---|
| `DPP_READERS` | names of the readers, comma-separated (`STAGING,PRODUCTION`) |
| `DPP_READER_<NAME>_POD` | base URL of the pod, as the pod knows it |
| `DPP_READER_<NAME>_DID` | the reader's `did:oyd` |
| `DPP_READER_<NAME>_DOC_KEY` | its document key, multibase |

A configuration in which two readers share a pod or a DID, a reader DID equals
the service DID, or a key does not decode is refused as a whole; the service
logs why and lists no reader. `bin/rails dpp:readers:check` checks the service
DID and every reader DID against the key that resolves for it.

**The read grant.** As protected reader the service signs its own read grant
(`typ` `pod-read-delegation+jwt`, `kid` `<reader DID>#key-doc`): `iss` and `sub`
are the reader DID, `aud` is the pod, `collections` names the one collection,
`act` is `["read"]`, and there is no `product_id`. The economic operator signs
nothing for it and cannot revoke it. The grant is not stored: it is signed
again whenever it is needed, from the start of the current 30-day window, and
runs 90 days from there. Ed25519 signatures are deterministic, so all through a
window every instance of the service presents the same grant under the same
`jti`, the name under which the custodian lists and revokes it; a grant in use
has at least 60 days left. Client assertion and DPoP proofs are signed with the
same document key of the reader DID. The token lasts at most 600 s and is
fetched again with the same grant shortly before it runs out.

The service reads with it what a write delegation may not: the object list of
the collection and the index cards and their meta, to find the controlled card
of a passport (AccessClasses.md §6) when its object id is not known. A pod that
does not know the reader answers the grant with `invalid_grant`. A reader with
access rights then gets the public part, with a header that says the
controlled part is unavailable and why (AccessClasses.md §8); the public read
path is untouched.
Before a passport with attributes that are not public is written to a
collection, the service asks for a token under the read grant for that
collection; if the pod answers `invalid_grant`, the passport is refused before
anything is written (AccessClasses.md §6).
`bin/rails dpp:readers:measure DPP=<digitalProductPassportId>` reads the
controlled card of a passport this way and reports what came back, without
printing values, grant or token.

## 4. Provisioning at the intermediary

The intermediary creates pod, organization and collection and **enters the
holder's identity DID as the `controller_did` of the collection**. All that is
handed over is:

```json
{ "base_url": "https://dpp.go-data.at", "collection_id": "4" }
```

Both are **not secret**: provisioning hands out nothing confidential.

> **Prerequisite:** the economic operator needs an identity DID *before* they
> can be provisioned. That is a new hurdle in onboarding and needs a guided
> creation flow, otherwise we merely shift the problem to the customer.
> See open item 5.

## 5. The delegation assertion

Header:

```json
{ "alg": "EdDSA", "typ": "dpp-delegation+jwt",
  "kid": "did:oyd:zQmPPwHJK…#key-doc" }
```

Payload:

```json
{
  "iss":        "did:oyd:zQmPPwHJK…",
  "sub":        "did:oyd:zQmSERVICE…",
  "aud":        "https://dpp.go-data.at",
  "collection": "4",
  "product_id": "https://id.lumina.example/01/09520123456795",
  "act":        ["create", "update", "delete"],
  "purpose":    "dpp-hosting",
  "iat":        1786960000,
  "nbf":        1786960000,
  "exp":        1794736000,
  "jti":        "b2f1c9e4a7d05386"
}
```

| Claim | Meaning | Mandatory |
|---|---|---|
| `iss` | identity DID of the holder; must be the `controller_did` of the collection | yes |
| `sub` | DID of the mandated DPP Service | yes |
| `aud` | `base_url` of the pod — prevents reuse at a different pod | yes |
| `collection` | target collection | yes |
| `product_id` | subject of the delegation, exactly one product. No wildcard — see D2 | yes |
| `act` | permitted operations. Extensible array; accepted today are `create`, `update`, `delete`, anything else is refused. `read` is reserved — see D3 | yes |
| `purpose` | purpose limitation in the sense of Art. 12(e) DGA; is written into the event log | yes |
| `nbf`/`exp` | validity window | yes |
| `jti` | uniqueness, replay protection | yes |

**Reading in order to write.** A delegated token may read the **payload** of the
objects it may write — exactly those whose subject the delegation names. That
read is not an operation in the sense of `act`: it cannot be requested, it
cannot be held on its own, and it exists only as the reverse side of a write
permission. `read` stays reserved as an `act` value (D3); a mandate that
authorises reading alone does not exist. The DPP Service reads the public part
of a passport over the custodian's public path, without a token (§12). It reads
this way only the controlled card of a passport held as two cards
(AccessClasses.md §6), and only right before it writes that passport: the
controlled card carries the same `uniqueProductIdentifier` as the public one,
so the same delegation names it, covers writing it and covers reading it.

Not included is the object's index card — `meta`, schema, visibility. A
delegated token that asks for it (`show_meta=TRUE`) is refused; anything beyond
the payload needs a token of the holder's own. The reasoning is D4.

The `typ` header is not cosmetics: without it a delegation can be abused as a
write token against the DPP Service or as a client assertion
(RFC 8725 §3.11). Each of the three statements gets its own `typ`, and every
verifier rejects foreign `typ` values.

**Why `product_id` and not the passport DID:** at `CreateDPP` in variant A the
passport DID does not exist yet — it is only minted after the pod has been
confirmed reachable. The `product_id` is known at that point and is anyway the
key under which the pod publicly delivers.

## 6. Client assertion and DPoP

Client assertion (RFC 7523 §3), `typ: "client-assertion+jwt"`:

```json
{ "iss": "did:oyd:zQmSERVICE…", "sub": "did:oyd:zQmSERVICE…",
  "aud": "https://dpp.go-data.at/oauth/token",
  "iat": 1786960000, "exp": 1786960060, "jti": "…" }
```

DPoP proof (RFC 9449), `typ: "dpop+jwt"`, the header contains the public
key as a JWK:

```json
{ "htm": "POST", "htu": "https://dpp.go-data.at/oauth/token",
  "iat": 1786960000, "jti": "…" }
```

Both are signed with the same key as the service DID. The pod binds the issued
access token to the thumbprint (`cnf.jkt`) and afterwards accepts it only with
a matching proof.

On requests to the pod's *resource* endpoints — everything after the token
request — the proof additionally carries `ath`, the base64url SHA-256 of the
access token it accompanies (RFC 9449 §7.1). Without it a proof captured from
one request could be replayed alongside a different token. A token request has
no `ath`, because no access token exists yet; that is why the conformance
vectors, which all target the token endpoint, do not show one. The DPP Service
sends `ath` on every resource request: a verifier that ignores the claim is not
broken by its presence, and one that follows the RFC needs it.

> **No `.well-known` needed.** The pod learns the key from the DPoP proof and
> the service identity from the resolvable DID. A
> `GET /.well-known/dpp-service` returning `{ "did": …, "audience": … }` is
> still sensible — but as **discovery** for the holder, so that they know what
> to enter in `sub`, not as a security mechanism.
>
> The same document lists the reader DIDs (§3), one entry per pod:
> `"readers": [{ "pod": "https://dpp.go-data.at", "did": "did:oyd:…" }]`. The
> intermediary compares the entry for its own pod with the value it has
> configured; it does not take the reader DID from here. Without configured
> readers the member is absent.

## 7. Token request

```
POST {base_url}/oauth/token
DPoP: <proof>
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
&assertion=<delegation assertion>
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<client assertion>
```

Response:

```json
{ "access_token": "…", "token_type": "DPoP", "expires_in": 600,
  "scope": "collection:4 product:https%3A%2F%2Fid.lumina.example%2F01%2F09520123456795 act:create,update" }
```

No refresh token. If the access token expires, a new one is fetched with the
same delegation — the delegation *is* the long-lived artifact, and unlike a
refresh token it is useless to anyone except the service named in `sub`.
A resource request the pod answers with `401 invalid_token` is repeated once,
with a token newly fetched under the same delegation, at most once per incoming
request; `invalid_grant` at the token endpoint is final and is not repeated.

## 8. Verification rules in the pod

Fail-closed, in this order. Every failure is `invalid_grant` unless §15 names a
more specific code for that situation; the reason goes into the log, not into
the response.

1. The delegation's `typ` is `dpp-delegation+jwt`, `alg` is `EdDSA`.
2. `iss` is a DID. Resolve it (cache: positive 300 s, negative 60 s), take the
   document key, verify the signature.
3. `aud` matches the pod's own `base_url`.
4. `nbf` ≤ now ≤ `exp`, tolerance ±60 s, `exp - iat` ≤ `MAX_DELEGATION_LIFETIME`.
5. `jti` is **not** on the collection's revocation denylist. It is a name, not a
   nonce: the delegation lives 90 days (§10), is presented again at every token
   request (§7), and §11 uses exactly this `jti` as the revocation handle. A
   one-shot nonce store here would make every delegation single-use and turn the
   second token request of the day into a rejected replay. Replay protection
   sits on the short-lived statements, where it already is — rule 7 and rule 9.
6. `iss` is the registered `controller_did` of the collection named in
   `collection`, and that collection is not locked for write acts. The
   intermediary locks a collection when the DPP hosting contract (D2A) for it
   is revoked (§12). A write delegation for a locked collection is refused with
   `invalid_grant`, at every attempt. Write tokens already issued for the
   collection stop working at once: the resource answers them with
   `401 invalid_token`, the one new token request that follows (§7) is refused
   with `invalid_grant`, and the write ends there. With no token issued any
   more, the read that goes with a write permission (§5) ends as well. Write
   requests with any other token of the pod, such as one of the owner
   organisation, are answered with `403 collection_write_locked`. Reading is not
   affected: the public path (§12) and read grants (`pod-read-delegation+jwt`,
   §3) work as before.
7. Client assertion valid, `iss == sub`, `aud` is the token endpoint,
   lifetime ≤ 60 s, its own `jti` store.
8. **The delegation's `sub` == the client assertion's `iss`.** Without this
   check the delegation is a bearer artifact.
9. DPoP proof valid, `htm`/`htu` match, lifetime ≤ 30 s.
10. `act` ⊆ the operations permitted for this collection, and every value is one
    the pod accepts today (`create`, `update`, `delete`). An unknown value is
    refused rather than ignored — see D3. Both cases answer
    `insufficient_scope`, not `invalid_grant`. Reading the payload of a named
    object carries no `act` value and is checked without one — see D4.
11. `product_id` is one concrete identifier. `"*"` or any other pattern is
    refused with `invalid_grant` — see D2.

Only then is a token issued, bound to `cnf.jkt`, with
`expires_in = min(600, exp − now)`.

## 9. What the DPP Service stores

| Field | Content |
|---|---|
| `storage_base_url` | base URL of the pod, plaintext |
| `storage_collection_id` | collection, plaintext |
| `storage_delegation` | the delegation assertion, plaintext |

The delegation is not a secret: without the private key of the service DID it
is useless. This removes the credential hoarding of problem 4, and
`KEY_VAULT_KEK` is needed only for the passport keys of variant A.

The header `X-DPP-Storage` carries:

```json
{ "base_url": "https://dpp.go-data.at", "collection_id": "4",
  "delegation": "eyJhbGciOiJFZERTQSIsInR5cCI6ImRwcC1kZWxlZ2F0aW9uK2p3dCJ9…" }
```

## 10. Lifetimes

| Artifact | Proposal | Rationale |
|---|---|---|
| Delegation | 90 days | long enough that updates run without the holder's involvement; short enough that a forgotten delegation expires by itself. Renewal is a signed act of its own (§11), so the figure is the interval at which the holder has to reach for their key per passport |
| Client assertion | 60 s | is created anew per token request |
| DPoP proof | 30 s | is created anew per request |
| Access token | 10 min | short, because it can be re-fetched at will |
| `jti` store | until `exp` + 60 s | after that `exp` protects |

Public read paths need **no** token — by far the largest share of accesses
therefore runs entirely without this apparatus. That includes the DPP Service's
own reads of a passport held at a custodian (§12).

## 11. Renewal

A mandate has a lifetime and a passport does not. Ninety days after it was
signed, the delegation the service holds for a passport stops being redeemable,
while the passport it is about goes on being updated and, eventually, deleted.
Handing over a fresh one is therefore an ordinary operation, not an exception.

```
POST /dpp/v1/dpps/{dppId}/delegation
X-DPP-Storage: {"base_url":"…","collection_id":"…","delegation":"<fresh JWT>"}
```

Answers `204` and nothing else. The passport is not touched, and the fresh
mandate was signed by the caller moments earlier, so there is nothing to report
back that they do not already hold. Failures answer with the Result object of
EN 18222:2026 Table 12, mapped as in §15.

The mandate in place is readable:

```
GET /dpp/v1/dpps/{dppId}/delegation
```

Answers `200` with `{ jti, exp, act, collection, base_url }`, read from the
stored assertion without being verified — an expired mandate is exactly what the
caller is here to find out about. The holder keeps its own record of what it
signed, and after a restore from an older backup the two drift apart; the drift
is otherwise silent, the holder counting a passport as provided for while the
service sits on a mandate that no longer works. Nothing secret is disclosed:
all five values were signed by the owner, who is the only one allowed to read
them. Every value is `null` when the stored assertion can no longer be read,
which is the same answer in a different shape — the service holds nothing it
could redeem. `404` for a passport no custodian holds.

**An operation of its own, not a header on `PATCH`.** `PATCH` carries RFC 7396
semantics over the document (EN 18222:2026, Table 6). Replacing a mandate is an
act about custody, not a field of the passport. Two meanings in one call blur
both, and the client saves exactly one request.

**The stored mandate is not an authority here.** The reason to be on this path
is that it has expired, so nothing on it may depend on the stored delegation
still being redeemable. It is still *read*, without being trusted, for the two
comparisons in the table below; a stored mandate that can no longer be parsed
leaves nothing to compare against and both fall away.

What the service checks, in this order:

| Check | Refusal |
|---|---|
| the caller owns the passport | `ClientForbidden` (403) |
| the passport is held by a custodian at all | `ClientErrorBadRequest` (400) |
| the fresh mandate names the same `aud` and `collection` as the one in place | `ClientErrorBadRequest` (400), pointing at `POST /dpps/{dppId}/custody` |
| its `product_id` is the passport's `uniqueProductIdentifier` | `ClientForbidden` (403) |
| its `act` covers everything the stored one covered | `ClientForbidden` (403), log reason `insufficient_scope` |
| its `exp` lies after the stored `exp` | `ClientErrorBadRequest` (400) |
| the pod issues a token for it | per §15 |

The last one is the only evidence that the fresh mandate is worth anything, so
it happens before the stored one is overwritten: a broken mandate must never
replace a working one. The three before it guard against the mistake this path
invites, which is handing over the wrong artefact — a mandate for a different
passport, one that grants less than the one in place, or one that runs out
sooner. None of the three is a case anyone means to be in.

A mandate naming a *different* custodian is not refused because it is invalid
but because it means something else: that is a handover, it moves the document,
and it has its own operation (`POST /dpps/{dppId}/custody`).

At the custodian a renewal supersedes what it replaces. The pod keeps one
record per `(collection, product_id, sub)`, so redeeming the fresh mandate
overwrites the record that named the previous one and puts that one's `jti` on
the revocation list, where it stays until it would have expired anyway. Without
that step the predecessor would remain a signed, redeemable artefact for the
rest of its 90 days while the record naming it had been rewritten — leaving the
holder nothing to withdraw it by. The order is what makes this safe: the
service obtains a token with the fresh mandate before it replaces the stored
one, so the predecessor lapses exactly when its successor has proven itself,
and a renewal that fails leaves it untouched. Mandates held by *different*
services for the same passport are unaffected (D1); each has a record of its
own.

`product_id` is checked at `CreateDPP` in the same way. A mandate that is
redeemable but names another passport would otherwise be stored, and the
mismatch would surface at the pod on the first write — after a DID had been
minted for it.

## 12. Revocation

- **By the holder:** revoke the delegation in the pod (`jti` on a denylist).
  Takes effect immediately, affects exactly one passport at exactly one service.
- **By expiry:** after `exp`, without involvement.
- **By DID revocation:** if the holder revokes their identity DID, resolution
  fails and all their delegations die. Careful: the positive cache window
  (300 s) is the delay with which this takes effect.
- **By the intermediary:** when the D2A for a collection is revoked, the
  intermediary locks the collection for write acts (`create`, `update`,
  `delete`). No write delegation for it is redeemed any more, and write tokens
  already issued stop working at once (§8 rule 6). The lock is final: neither
  the owner organisation nor a fresh delegation (§11) lifts it.

All four end writing, not reading. The DPP Service reads the public part of a
passport over the custodian's public path
(`GET {base_url}/dpp/v1/dpps/{dppId}?representation=full`, `Accept:
application/json`), without a token and without the delegation. This holds for
`ReadDPPById` and `ReadDPPByProductId` as well as for the read that precedes
`UpdateDPP` and a change of custodian. A passport whose delegation has expired
or been revoked therefore stays readable through the service, as it does at the
custodian; `UpdateDPP` and `DeleteDPPById` answer `ClientNotAuthorized` until a
fresh mandate is handed over (§11), and for good once the collection is locked.

## 13. Key loss

This is the point that hurts the most in production. If the holder loses the
document key of their identity DID, they can neither delegate nor write, and
their passports freeze.

Recommendations:

- Keep the revocation key separate from the document key — it is the only way
  to terminate a DID cleanly.
- Point out safekeeping explicitly during onboarding and offer both for
  download (the registrar response delivers them exactly once).
- **Emergency path at the intermediary:** the `controller_did` of a collection
  must be changeable upon justified request, otherwise a key loss is
  equivalent to data loss. This path is a back door into the neutrality
  architecture and must therefore be documented, logged, rate-limited and
  bound to an identity check outside the system. It belongs in the contract,
  not only in the code.

## 14. No compatibility mode

**What that does and does not cover.** It is a statement about the **DPP
Service**: it holds no `client_secret`, so there is exactly one way for it into
a pod. Two ways would mean the weaker one survives, which is the whole point.

It is not a statement about dc-pod. The pod platform serves other, domain
specific applications that legitimately use `client_credentials`, and that grant
stays: `dc-base` lists `authorization_code` and `client_credentials`
unconditionally and appends whatever `DC_GRANT_FLOWS` names, so the delegation
grant sits *next to* them rather than replacing anything. A pod without
`DC_GRANT_FLOWS=delegation` behaves exactly as before.

Worth keeping straight when writing about this: the five problems in §1 remain
true for anything that still authenticates with a shared secret. The claim this
model earns is "the DPP path needs no shared secret", not "the intermediary
works without shared secrets".

## 15. Error mapping (EN 18222:2026 Table 15)

`invalid_dpop_proof` (RFC 9449 §7.1) and `insufficient_scope` (RFC 6750 §3.1)
are prescribed by their respective RFCs; where this table names one of them it
takes precedence over the `invalid_grant` default of §8.

| Situation | Pod | DPP Service → client |
|---|---|---|
| delegation expired or revoked | `invalid_grant` | `ClientNotAuthorized` (401) |
| `iss` not the controller of the collection | `invalid_grant` | `ClientNotAuthorized` (401) |
| `act` does not cover the operation | `insufficient_scope` | `ClientForbidden` (403) |
| collection locked for write acts, write delegation presented | `invalid_grant` | `ClientNotAuthorized` (401) |
| collection locked for write acts, write token already issued | `401 invalid_token`, then `invalid_grant` for the new token (§7) | `ClientNotAuthorized` (401) |
| collection locked for write acts, any other token of the pod | `403 collection_write_locked` | — (not a path of the DPP Service) |
| DPoP proof missing or not matching | `invalid_dpop_proof` | `ClientNotAuthorized` (401) |
| `iss` not resolvable | — (refused by the DPP Service before the pod is asked) | `ClientNotAuthorized` (401) |
| passport with attributes that are not public, this service not entered as reader of the target collection | `invalid_grant` on the read grant (§3) | `ClientErrorBadRequest` (400) with message code `readerNotEntered`, nothing written |
| read with access rights, this service not entered as reader of the passport's collection | `invalid_grant` on the read grant (§3) | `200` with the public part and `X-DPP-Controlled-Part: unavailable;reason=readerNotEntered` |
| pod not reachable | — | `ServerErrorBadGateway` (502) |

The pod does not say which rule a refused grant failed (§8), so the DPP
Service cannot tell an expired or revoked delegation from one whose `iss` is
not the controller of the collection: every `invalid_grant` becomes
`ClientNotAuthorized`, and the distinction lives in the pod's log. Only
`insufficient_scope` becomes `ClientForbidden`. The DPP Service checks
signature, `sub`, `aud`, `collection`, validity window, `product_id` and `act`
of a delegation itself before it presents it, and answers a failure there the
same way: `act` with `ClientForbidden`, everything else with
`ClientNotAuthorized`. A delegation for a product other than the passport's
`uniqueProductIdentifier` is refused with `ClientForbidden` (§11).

## 16. Decisions taken (2026-08-19)

D1 to D3 were settled before implementation started, D4 in the first joint
run, D5 and D6 in the architecture pass against the code. They are binding for
both sides; changing one means changing this document first.

**D1 — Several simultaneous delegations for the same `product_id`: permitted.**
The uniqueness constraint is `(collection, product_id, sub)`, not
`(collection, product_id)`. Rationale: a delegation is a statement about
*authorisation*, not a lock. Exclusivity at this layer would open a window
during a provider handover in which nobody may write — precisely the property
the exit argument rests on — and it would not even solve the problem it looks
like it solves, since two updates from the *same* service collide in the same
way. Concurrent writes belong one layer up, in a version precondition on
`UpdateDPP` (open item 6); without one the later write wins. The write log
stays the record of who changed what.

**D2 — `product_id: "*"` is not offered.** One delegation per passport, one
signature by the holder per `CreateDPP`. This keeps the binding to the object
rather than to the account, which is the point of the whole construction. The
operational cost is real: the holder needs signing capability in their process,
and the tempting way out — the service holding the holder's key — would void
the model entirely. If the signature load turns out to be prohibitive, the
extension is an explicit **list** of `product_id` values or a bounded prefix,
both of which stay checkable. A wildcard is not reversible once customers hold
one, so it is ruled out rather than deferred.

**D3 — `read` is reserved, not issued.** `act` is an extensible array of
strings; today only `create`, `update` and `delete` are accepted and everything
else is refused fail-closed with its own log reason. What must *not* happen is
closing the vocabulary: no enum type, no `CHECK` constraint on three values, no
`act` column that only fits what exists today. Reading controlled data under
EN 18239:2026 needs a role attestation model — who says that someone *is* a
refurbisher or a market surveillance authority — and that is a separate piece
of work, not a fourth value in this array. It is built that way: access grants
at the DPP Service say who may read which class (AccessClasses.md §7), and the
service reads the controlled part at the pod under the read grant of its reader
DID (§3), not under a write delegation. Reserving the slot keeps a later
addition a code change instead of a migration.

**D4 — A delegated token may read what it may write, payload only.** Found on
2026-08-19 in the first joint run: `CreateDPP` completed end to end, `UpdateDPP`
failed one step earlier, at `GET /object/:id/read`. The pod refused it because a
delegated token deliberately carries none of the `read`/`write`/`admin` scopes,
and the refusal came from Doorkeeper, not from the delegation guard. Neither
side had implemented anything wrong: the specification said which operations a
delegate may perform and never said how it reaches the state it is supposed to
change. A merge patch cannot be formulated without the current document.

The rule is in §5. What makes it not a widening of the mandate: with `update` or
`delete` in `act`, the service ends up holding the document anyway. `UpdateDPPById`
applies an RFC 7396 merge patch and answers with the updated passport (EN
18222:2026, Table 6); `DeleteDPPById` writes the final version as `Archived` before
the object goes. A write-only mandate would therefore not keep the content from
the delegate — it would only make the operations it grants impossible. That is
the argument, and it is worth being precise about it: "the passport is public
via its product identifier anyway" is *not*, because a passport need not be
public in all its parts.

Two alternatives were weighed and dropped. Replacing `PATCH` with a **full `PUT`** discards the RFC 7396 semantics the
service API is built on and turns every field change into a full replacement,
which loses concurrent edits. Letting the **pod apply the patch itself** looks
attractive, because then the service would never read — but the service has to
answer `UpdateDPP` with the updated passport, so it would read it back
immediately afterwards, and RFC 7396 semantics would have moved into a
domain-agnostic store, which is the wrong layer for them.

The boundary is the index card. Payload yes, `meta` no: what a delegate needs is
the document it rewrites, not the object's visibility, schema or history of
ownership. `show_meta=TRUE` is therefore refused for a delegated token.

The conformance vectors cannot pin this rule down — every one of them is a
request to the token endpoint, and this is about a resource request. It is
pinned instead by two tests on the pod side: reading the subject the delegation
names succeeds, reading a different subject in the same collection does not.
Whoever changes that behaviour has to change those tests, which is where the
next implementer will look.

The DPP Service itself reads the public part of a passport over the public path
(§12), so its reads do not end with the mandate.

**D5 — Where the pod builds this.** Nothing about the three assertions is
DPP-specific, so nothing about them is built in the DPP-specific layer.
`dc-base` gets the generic parts: resolving a foreign `did:oyd` with the cache
discipline of rule 2, and verifying an EdDSA JWS against a key from a DID
document. `dc-pod` gets the whole delegation apparatus: `controller_did` on the
collection, the rules of §8, token issuance bound to `cnf.jkt`, the `jti`
stores, revocation, and scopes **as a mechanism**. `pod-dpp` contributes one
thing only — which field of a stored object the `product_id` of a delegation
denotes. The wire claim stays `product_id`; inside `dc-pod` the column is
called `subject_id`, because a layer that must not know what a passport is must
not name its columns after one. Detail in
`dc-pod/docs/Delegation-Implementation.md`.

**D6 — A registered Doorkeeper grant flow, not a separate endpoint.**
Doorkeeper 5.9 does not ship `urn:ietf:params:oauth:grant-type:jwt-bearer`, but
it does ship the registry for it: `Doorkeeper::GrantFlow.register` with an own
strategy class, served by the stock tokens controller at the `POST
{base_url}/oauth/token` of §7. The endpoint is contract, so a separate one was
never a real option; the alternative of the `doorkeeper-grants_assertion` gem
was rejected because it covers only the assertion and would have to be fought
over client assertion, DPoP and `cnf.jkt`. The success and error bodies are
built by hand: Doorkeeper's own token response hard-codes `token_type` as
`Bearer`, and its error response maps everything but two client errors to
HTTP 400 with an I18n description that does not exist for
`invalid_dpop_proof`. This answers open item 1.

## 17. Open items

1. ~~Own Doorkeeper grant or an extension?~~ Answered by D6: a registered
   grant flow at the stock token endpoint.
2. How does the intermediary enter `controller_did` — UI, API, both?
   API first; the UI can follow. Implemented as API: `collections#create` and
   `#update` merge `data["meta"]`, so `controller_did` and `allowed_act` are
   handed over at provisioning without a code change on the pod.
3. ~~Does the pod need a view of "which delegations exist"?~~ Yes.
   `GET /collection/:id/delegations` lists them and `DELETE /delegation/:id`
   is the revocation of §12 — the same handle serves both purposes.
4. ~~`jti` store: Redis or database?~~ Database; there is no Redis in the
   deployment at all. Note which `jti` is stored where: the client assertion's
   and the DPoP proof's, recorded **on success** rather than on passing their
   rule, so that a request failing later cannot burn a legitimate assertion.
   The delegation's `jti` is not stored at all — it is the revocation handle of
   rule 5.
5. Guided DID creation flow in onboarding — clarify responsibility. D2 makes
   this load-bearing: without signing capability at the holder, per-passport
   delegation does not work in practice.
6. Version precondition on `UpdateDPP` — which mechanism (`If-Match` with an
   ETag, or an explicit version field in the payload)? Follows from D1 and is
   the one thing D1 pushes down into the write layer.
