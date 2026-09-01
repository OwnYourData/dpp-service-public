# Delegation without a shared secret

**Status:** Implemented and in production. The delegation fully replaces the
storage JWT that carried `client_secret` in `X-DPP-Storage`; no `client_secret`
is stored or accepted any more. There was **no migration path** — the pods,
collections and OAuth applications from before were deleted and created anew.


---

## 1. Why

Today the economic operator hands the DPP Service a storage JWT containing
`client_id` and `client_secret`. That is not an access token, it is the
credentials themselves. Five problems follow from this:

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

On top of that: the storage JWT is built with `alg: none` today, so it is no
proof at all. Whoever intercepts one can have data written into someone else's
pod.

**The actual design flaw:** the holder already has a signing key and uses it in
the same call to sign their bearer token for the DPP Service. They nevertheless
hand over a password. Public-key cryptography on one side of the request, a
shared secret on the other.

## 2. Target picture

Three signed statements, one key model, **no secret anywhere**:

| Statement | issued by | addressed to | Purpose |
|---|---|---|---|
| **Delegation Assertion** | economic operator | pod | "This service may store this passport in this collection" |
| **Client Assertion** | DPP Service | pod (token endpoint) | "I am the service that the delegation names" |
| **DPoP Proof** | DPP Service | pod (every request) | "I hold the key this token is bound to" |

Standards: RFC 7523 (JWT as a grant *and* as client authentication), RFC 9449
(DPoP), RFC 8725 (JWT best practices, in particular the `typ` header), RFC 7009
(revocation). All within what prEN 18239 §6.2 provides for with "OAuth 2.0 /
JWT bearer".

## 3. Keys and identities — do not confuse them

| What | Who holds the private key | What for |
|---|---|---|
| **Identity DID of the economic operator** | the economic operator | write token to the DPP Service, **delegation assertion**, owner binding |
| **Passport DID** (one per DPP) | Variant A: the DPP Service; Variant B: the holder or the secure element | identifier of the passport, commitment of the payload hash (see `Integrity.md`) |
| **Service DID of the DPP Service** | the DPP Service | client assertion, DPoP |

The delegation is signed with the **identity DID**, not with the passport DID.
At `CreateDPP` the passport DID does not even exist yet in variant A.

## 4. Provisioning — what changes at the intermediary

So far: create pod, organization, collection and OAuth application, then hand
over `client_id` + `client_secret`.

New: create pod, organization and collection and **enter the holder's identity
DID as the `controller_did` of the collection**. All that is handed over is
now:

```json
{ "base_url": "https://dpp.go-data.at", "collection_id": "4" }
```

Both are **not secret**. So the provisioning step does not disappear, it just
no longer hands out anything confidential.

> **Prerequisite:** the economic operator needs an identity DID *before* they
> can be provisioned. That is a new hurdle in onboarding and needs a guided
> creation flow, otherwise we merely shift the problem to the customer.
> See open item 7.

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
  "product_id": "https://id.lumina.example/01/09520123456791",
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
authorises reading alone does not exist.

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
  "scope": "collection:4 product:https%3A%2F%2Fid.lumina.example%2F01%2F09520123456791 act:create,update" }
```

No refresh token. If the access token expires, a new one is fetched with the
same delegation — the delegation *is* the long-lived artifact, and unlike a
refresh token it is useless to anyone except the service named in `sub`.

## 8. Verification rules in the pod

Fail-closed, in this order. Every failure is `invalid_grant` unless §14 names a
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
   `collection`.
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

| Field | so far | new |
|---|---|---|
| `storage_base_url` | plaintext | unchanged |
| `storage_collection_id` | plaintext | unchanged |
| `storage_credentials_enc` | AES-256-GCM encrypted | **dropped** |
| `storage_delegation` | — | the delegation assertion in plaintext |

The delegation is no longer a secret: without the private key of the service
DID it is useless. This removes the credential hoarding from problem 4 and
`KEY_VAULT_KEK` is then only needed for the passport keys of variant A.

The header is still called `X-DPP-Storage`, its content in future is:

```json
{ "base_url": "https://dpp.go-data.at", "collection_id": "4",
  "delegation": "eyJhbGciOiJFZERTQSIsInR5cCI6ImRwcC1kZWxlZ2F0aW9uK2p3dCJ9…" }
```

## 10. Lifetimes

| Artifact | Proposal | Rationale |
|---|---|---|
| Delegation | 90 days | long enough that read-through and updates run without the holder's involvement; short enough that a forgotten delegation expires by itself. Is renewed at the next write operation, where the holder signs anyway |
| Client assertion | 60 s | is created anew per token request |
| DPoP proof | 30 s | is created anew per request |
| Access token | 10 min | short, because it can be re-fetched at will |
| `jti` store | until `exp` + 60 s | after that `exp` protects |

Public read paths need **no** token — by far the largest share of accesses
therefore runs entirely without this apparatus.

## 11. Revocation

- **By the holder:** revoke the delegation in the pod (`jti` on a denylist).
  Takes effect immediately, affects exactly one passport at exactly one service.
- **By expiry:** after `exp`, without involvement.
- **By DID revocation:** if the holder revokes their identity DID, resolution
  fails and all their delegations die. Careful: the positive cache window
  (300 s) is the delay with which this takes effect.

## 12. Key loss

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

## 13. No compatibility mode

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

## 14. Error mapping (EN 18222:2026 Table 16)

`invalid_dpop_proof` (RFC 9449 §7.1) and `insufficient_scope` (RFC 6750 §3.1)
are prescribed by their respective RFCs; where this table names one of them it
takes precedence over the `invalid_grant` default of §8.

| Situation | Pod | DPP Service → client |
|---|---|---|
| delegation expired or revoked | `invalid_grant` | `ClientNotAuthorized` (401) |
| `iss` not the controller of the collection | `invalid_grant` | `ClientForbidden` (403) |
| `act` does not cover the operation | `insufficient_scope` | `ClientForbidden` (403) |
| DPoP proof missing or not matching | `invalid_dpop_proof` | `ClientNotAuthorized` (401) |
| DID not resolvable | `invalid_grant` | `ServerErrorBadGateway` (502) |
| pod not reachable | — | `ServerErrorBadGateway` (502) |

## 15. Decisions taken (2026-08-19)

These three were settled before implementation started. They are binding for
both sides; changing one means changing this document first.

**D1 — Several simultaneous delegations for the same `product_id`: permitted.**
The uniqueness constraint is `(collection, product_id, sub)`, not
`(collection, product_id)`. Rationale: a delegation is a statement about
*authorisation*, not a lock. Exclusivity at this layer would open a window
during a provider handover in which nobody may write — precisely the property
the exit argument rests on — and it would not even solve the problem it looks
like it solves, since two updates from the *same* service collide in the same
way. Concurrent writes are handled one layer up: `UpdateDPP` takes a version
precondition and a stale one is refused. The write log stays the record of who
changed what.

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
prEN 18239 needs a role attestation model — how does the pod learn that someone
*is* a refurbisher or a market surveillance authority — and that is a separate
piece of work, not a fourth value in this array. Reserving the slot keeps the
later addition a code change instead of a migration.

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
via its product identifier anyway" is *not*, because passports need not stay public, and the
same objection is what rules out reading through the public path.

Three alternatives were weighed and dropped. Reading through the **public path**
holds only as long as every passport is public — the assumption we do not want
to build on, and the question would return later with data already in place.
Replacing `PATCH` with a **full `PUT`** discards the RFC 7396 semantics the
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

## 16. Open items

1. Own Doorkeeper grant or an extension? Doorkeeper does not ship
   `urn:ietf:params:oauth:grant-type:jwt-bearer`. To be answered by the
   architecture pass against the code, not in the abstract.
2. How does the intermediary enter `controller_did` — UI, API, both?
   API first; the UI can follow.
3. Does the pod need a view of "which delegations exist"? Art. 12(c) implies
   disclosure on request; a view would be the better implementation. D1 makes
   this more pressing, since several may now be active at once.
4. `jti` store: Redis or database? It has to survive a restart. Database
   first, Redis is an optimisation.
5. Guided DID creation flow in onboarding — clarify responsibility. D2 makes
   this load-bearing: without signing capability at the holder, per-passport
   delegation does not work in practice.
6. Version precondition on `UpdateDPP` — which mechanism (`If-Match` with an
   ETag, or an explicit version field in the payload)? Follows from D1 and is
   the one thing D1 pushes down into the write layer.
