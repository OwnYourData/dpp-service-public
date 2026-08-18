# Delegation without a shared secret

**Status:** Draft, not implemented yet. Fully replaces the storage JWT with
`client_secret` from `X-DPP-Storage`. There is **no migration path** —
existing pods, collections and OAuth applications are deleted and created
anew.

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
| `product_id` | subject of the delegation. `"*"` permits the whole collection and should be the exception | yes |
| `act` | permitted operations, subset of `create`/`update`/`delete` | yes |
| `purpose` | purpose limitation in the sense of Art. 12(e) DGA; is written into the event log | yes |
| `nbf`/`exp` | validity window | yes |
| `jti` | uniqueness, replay protection | yes |

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

Fail-closed, in this order. Every failure is `invalid_grant`; the reason goes
into the log, not into the response.

1. The delegation's `typ` is `dpp-delegation+jwt`, `alg` is `EdDSA`.
2. `iss` is a DID. Resolve it (cache: positive 300 s, negative 60 s), take the
   document key, verify the signature.
3. `aud` matches the pod's own `base_url`.
4. `nbf` ≤ now ≤ `exp`, tolerance ±60 s, `exp - iat` ≤ `MAX_DELEGATION_LIFETIME`.
5. `jti` not seen before → store until `exp` + tolerance.
6. `iss` is the registered `controller_did` of the collection named in
   `collection`.
7. Client assertion valid, `iss == sub`, `aud` is the token endpoint,
   lifetime ≤ 60 s, its own `jti` store.
8. **The delegation's `sub` == the client assertion's `iss`.** Without this
   check the delegation is a bearer artifact.
9. DPoP proof valid, `htm`/`htu` match, lifetime ≤ 30 s.
10. `act` ⊆ the operations permitted for this collection.

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

## 13. Changeover

No compatibility mode. Order:

1. Pod: `controller_did` on the collection, JWT bearer grant, DID resolution
   with caching, `jti` store, DPoP.
2. DPP Service: switch `PodStorage` over to delegation, reuse
   `DidTokenVerifier` for the signature of the delegation, create the service
   DID and publish it under `/.well-known/dpp-service`, remove
   `storage_credentials_enc` by migration.
3. Delete existing passports, collections and OAuth applications.
4. Rewrite `docs/Guide.md` and `docs/Walkthrough_Pod_VarianteB.md`.

## 14. Error mapping (prEN 18222 Table 16)

| Situation | Pod | DPP Service → client |
|---|---|---|
| delegation expired or revoked | `invalid_grant` | `ClientNotAuthorized` (401) |
| `iss` not the controller of the collection | `invalid_grant` | `ClientForbidden` (403) |
| `act` does not cover the operation | `insufficient_scope` | `ClientForbidden` (403) |
| DPoP proof missing or not matching | `invalid_dpop_proof` | `ClientNotAuthorized` (401) |
| DID not resolvable | `invalid_grant` | `ServerErrorBadGateway` (502) |
| pod not reachable | — | `ServerErrorBadGateway` (502) |

## 15. Open items

1. Own Doorkeeper grant or an extension? Doorkeeper does not ship
   `urn:ietf:params:oauth:grant-type:jwt-bearer`.
2. How does the intermediary enter `controller_did` — UI, API, both?
3. Several simultaneous delegations for the same `product_id` to different
   services: permit or rule out?
4. Offer `product_id: "*"` at all? Convenient, but it dilutes the object
   binding that the whole model rests on.
5. Does the pod need a view of "which delegations exist"? Art. 12(c) implies
   disclosure on request; a view would be the better implementation.
6. `jti` store: Redis or database? It has to survive a restart.
7. Guided DID creation flow in onboarding — clarify responsibility.
8. Use delegation for **reading** controlled data according to prEN 18239 too?
   Then `act` would need a `read` value and the role logic would need a place.
