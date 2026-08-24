# DPP Service

**Context:** This page describes how to use the OwnYourData DPP Service, available at: https://dpp-service.ownyourdata.eu/api-docs/index.html

As of 2026-08-17. All example calls below have been checked against the running instance.
Whatever is not implemented yet is marked **(planned)**.

<details><summary>Implementation of the draft standard of CEN/CENELEC JTC 24 (2025 drafts)</summary>

The following overview shows which standard is used for what:
* **prEN 18222**: APIs for lifecycle management and search
  * endpoint and HTTPS/REST mapping (Tables 17–19)
  * lifecycle methods `CreateDPP`, `ReadDPPById`, `ReadDPPByProductId`, `ReadDPPVersionByProductIdAndDate`, `ReadDPPIdsByProductIds`, `UpdateDPP`, `DeleteDPPById`
  * registry API `registerDPP` (Clause 5)
  * fine-grained API for collections/elements (Clause 6)
  * generic status codes → HTTP (Table 16)
  * result/message object (Tables 13–15)
* **prEN 18223**: system interoperability (semantic data model)
  * DPP object attributes (Table 1)
  * DataElementCollection, Singlevalued-/MultivaluedDataElement, ValueElement (Tables 2–5)
  * product property including unit of measure/tolerance (Table 6)
  * serialisation
  * RFC 7396 merge patch semantics
* **prEN 18216**: data exchange protocols
  * TLS for the entire data exchange (§6.2)
  * JSON serialisation, content types
  * error handling
* **prEN 18219**: unique identifiers
  * identifier as a globally unique URI/URL including W3C DID schemes (the basis for `did:oyd`)
  * encoding of IDs as a single URL path segment
* **prEN 18221**: data storage, archiving and persistence (Module 6)
  * archiving of every DPP change
  * version history
  * retrieval of a version by date
* **prEN 18239**: access rights, information security, trade secrets
  * OAuth 2.0 / OpenID Connect / JWT bearer token
  * public reading vs. authenticated writing
  * signature verification implemented DID-based (`DPP_AUTH_MODE=did`), including owner binding
  * role model and data classes **(planned)**
* **prEN 18246**: data authenticity, reliability and integrity
  * the DID is the cryptographic anchor: the identifier is the hash over its own document
  * **(planned)** signatures over the DPP data itself, DID-/VC-based integrity
    (`did:oyd`, [CMSM](https://hackmd.io/0ikx7mLwQW2om-hZXTU1hg?view))
* **prEN 18220**: data carriers
  * ProductID as a resolvable web link to the DPP (the relation to the data carrier/QR code)
  * the ProductID is the form that goes onto the data carrier — it is itself
    the unique product identifier (creating the carrier is not part of the API)
* **DIN DKE SPEC 99100**: requirements for the data attributes of the battery passport
  * example battery passport attributes as DPP content

</details>

### Assumptions
* DID-first discovery model: a consumer resolves the DPP identifier with any resolver and reaches the product data over the service endpoints
* the `did:oyd` method is used as the identifier (prEN 18219)
  * blockchain-free, cryptographically secured link between identifier and content
  * can be operated locally (also in a closed system)
  * supports a version history
  * transparently addressable as `did:web`: every `did:oyd:{identifier}` also
    resolves as `did:web:oydid.ownyourdata.eu:{identifier}`, the DID document
    is available at `https://oydid.ownyourdata.eu/{identifier}/did.json`.
    Known limitation: the bridge currently also answers `200` with the document
    of a **revoked** `did:oyd`, while the proper `did:oyd` resolution correctly
    fails. A client that speaks only `did:web` therefore does not see a
    revocation; a fix in the registrar is pending.
  * it can be created with the CLI **or** over the REST API of the registrar
    (`POST https://oydid.ownyourdata.eu/1.0/create`, see
    [api-docs](https://oydid.ownyourdata.eu/api-docs/index.html)) — for the
    examples here the REST route is used, it needs no Docker
* **(planned)** claims / evidence in the DPP as W3C Verifiable Credentials
* **storage is decided per DPP**, not globally:
  * **Default:** the DPP document lives in the database of the DPP Service, which
    also serves it itself. Without further configuration this is the case.
  * **Optional:** if the header `X-DPP-Storage` is present at `CreateDPP`, the
    document moves into a hosting pod of the data intermediary
    [DID FlexCo](https://intermediary.at) — in the PACE project `https://dpp.go-data.at`.
    The pod then serves the public read paths itself.
  * Key material of managed DIDs **always** stays in the database of the DPP
    Service, encrypted (AES-256-GCM). It never moves into the pod.

## Sequence diagrams
In principle one has to distinguish whether
1) Variant A: the DPP Service creates the identifier itself (this requires the DPP Service to be trusted, since the private key is generated and read there), or
2) Variant B: the identifier is already supplied when a write operation is called

### Trusted DPP Service (variant A)
The simple variant, in which the manufacturer can create an identifier for every instance without having to deal with key management.

```plantuml
@startuml
autonumber
actor "Economic\noperator" as client
participant "DPP Service" as svc
participant "DID Resolver" as resolver
participant "Verifiable Data\nRegistry\n(oydid.ownyourdata.eu)" as vdr
database "DPP Service DB" as db
database "Hosting pod\n(DID FlexCo)\noptional" as pod
actor "Consumer" as consumer

note over db
  always local:
  - index (dpp_id, ProductID, product_key)
  - key material, encrypted
  - storage configuration
  additionally without a pod:
  - DPP document and versions
end note

note over pod
  only when X-DPP-Storage is set:
  - DPP document and versions
  - public delivery
  NEVER key material
end note

== CreateDPP ==
client -> svc : POST /dpp/v1/dpps\n(DPP object WITHOUT DigitalProductPassportID,\noptional header X-DPP-Storage)
note right of svc : no ID supplied\n-> service mints the DID (variant A)
opt X-DPP-Storage set
  svc -> pod : fetch token (client_credentials),\ncheck reachability
  pod --> svc : ok
  note right of svc : deliberately BEFORE minting -\nafterwards the serviceEndpoint\nchanges only via a DID update
end
svc -> svc : Oydid.create()\ncreate key pair (doc + revocation),\ncompute did:oyd,\nserviceEndpoint into the DID doc:\n{base}/dpp/v1/dppsByProductId/{ProductID}
svc -> vdr : publish DID document (POST /doc)
vdr --> svc : DID confirmed
svc -> db : store index and keys encrypted
alt without pod (default)
  svc -> db : store DPP document
else with pod
  svc -> pod : create index card + write document
  pod --> svc : object-id
end
svc --> client : 201 SuccessCreated\n{ dpp ID = did:oyd:..., ProductID unchanged }

== ReadDPP (consumer, DID-first discovery) ==
consumer -> resolver : resolve DID (any DID resolver)
resolver -> vdr : fetch DID document
vdr --> resolver : DID document\n(service.serviceEndpoint, public key)
resolver --> consumer : DID document
note over consumer : the serviceEndpoint runs over the ProductID -\nthe DID cannot appear in its own document,\nit is the hash over it
alt without pod
  consumer -> svc : GET serviceEndpoint (no token)
  svc -> db : read DPP document
  db --> svc : document
  svc --> consumer : 200 (DPP)
else with pod
  consumer -> pod : GET serviceEndpoint (no token)
  pod --> consumer : 200 (DPP)
end
note over consumer : planned: verify signature against\npublic key from the DID doc (18246)

== ReadDPPById (direct access, without discovery) ==
client -> svc : GET /dpp/v1/dpps/{did}  (public, no token)
svc -> db : read document (or fetch it from the pod)
db --> svc : DPP document
svc --> client : 200 Success (DPP)

== UpdateDPP ==
client -> svc : PATCH /dpp/v1/dpps/{did}\n(bearer token, merge patch)
svc -> svc : apply merge patch per RFC 7396
alt without pod (default)
  svc -> db : archive previous state to dpp_versions,\nwrite new state
else with pod
  svc -> pod : write new document
  note right of pod : the pod creates a new payload\nper write; the old one stays\nretrievable under its DRI
end
svc --> client : 200 Success (updated DPP)
note over svc, vdr : DigitalProductPassportID stays stable.\nA DID update per change is NOT implemented -\nthe version chain lives in dpp_versions or in the pod.\nplanned: commit a content hash per version to the OYDID log

== DeleteDPPById ==
client -> svc : DELETE /dpp/v1/dpps/{did}\n(bearer token)
alt without pod (default)
  svc -> db : keep the final version as "Archived"
else with pod
  svc -> pod : write the final state as "Archived",\nthen delete the object (soft delete)
end
svc -> svc : decrypt revocation key
svc -> vdr : revoke DID (service holds the key -> variant A)
vdr --> svc : revoked
svc -> db : remove the active row (archive stays)
svc --> client : 204 SuccessNoContent
@enduml
```

### Trustless DPP Service (variant B)
The private key stays in the secure element of the product via CMSM, while the DPP Service only stores and serves public data — without ever holding a key.

```plantuml
@startuml
autonumber
actor       "Economic\noperator" as client
entity      "Product\n(Secure Element)" as se
participant "Client service\n(CMSM logic)" as agent
participant "DPP Service" as svc
participant "DID Resolver" as resolver
participant "oydid registrar/VDR\n(oydid.ownyourdata.eu)" as reg
database    "Storage\n(DB or hosting pod)" as store
actor       "Consumer" as consumer

note over store
  storage of the DPP Service:
  - public DPP data
  - versions
  NO private keys
  (in variant B the service holds
   no key material at all)
end note

== Create a DPP (order) ==
client -> agent : create DPP (product data)

== Key pair generation (in the secure element) ==
agent -> se : request key pair (P-256)
se -> se : generate key pair
se --> agent : public key (PK)
note over se : the SK never leaves the secure element

== CreateDID (CMSM, two-step) ==
agent -> reg : initiate\n{ key: PK, doc.service.serviceEndpoint = public read URL,\n  options:{cmsm:true, key_type:p256} }
note right of reg : the serviceEndpoint runs over the ProductID.\nIf storage points at a hosting pod,\nits base_url has to go here.
reg -> reg : prepare DID, persist CMSM state
reg --> agent : sign payload (proof of SK possession)
agent -> se : sign payload
se -> se : sign with the SK
se --> agent : signature
agent -> reg : finish\n{ key: PK, options:{cmsm:true, sig} }
reg -> reg : verify signature, publish DID document
reg --> agent : did:oyd

== CreateDPP (standard, one call) ==
agent -> svc : POST /dpp/v1/dpps\n(DPP object WITH DigitalProductPassportID = did:oyd,\noptional header X-DPP-Storage)
note right of svc : DID supplied\n-> service mints nothing (variant B)
group planned
  svc -> reg : Oydid.read(did) - resolve & validate
  reg --> svc : DID document (public key, serviceEndpoint)
  svc -> svc : DID valid? serviceEndpoint pointing here?
end
note right of svc : refused if it does not resolve\nor points at another host
svc -> store : store public DPP data (NO keys)
store --> svc : ok
svc --> agent : 201 SuccessCreated { dpp ID = did:oyd, ProductID }
agent --> client : DPP created { dpp ID = did:oyd }

== ReadDPP (consumer, DID-first discovery) ==
consumer -> resolver : resolve did:oyd (any DID resolver)
resolver -> reg : fetch DID document
reg --> resolver : DID document (serviceEndpoint, public key)
resolver --> consumer : DID document
consumer -> store : GET serviceEndpoint (public read, no token)
store --> consumer : 200 (DPP)
note over consumer : planned: verify signature against the public key (18246)

== UpdateDPP ==
client -> agent : update DPP (changes)
agent -> svc : PATCH /dpp/v1/dpps/{did}\n(bearer token per 18239, merge patch)
svc -> store : archive previous state, write new state
store --> svc : ok
svc --> agent : 200 Success (updated DPP)
agent --> client : updated
group planned: DID update via CMSM (signed in the SE)
  agent -> reg : initiate DID update (new content hash)
  reg --> agent : sign payload
  agent -> se : sign payload
  se --> agent : signature
  agent -> reg : finish DID update (sig)
  reg -> reg : DID doc with new content hash,\nlog extended, publish
  reg --> agent : update confirmed
end
note over agent, reg : The identifier stays stable.\nThe DPP Service never holds a key.

== DeleteDPPById ==
client -> agent : delete DPP
agent -> svc : DELETE /dpp/v1/dpps/{did}\n(bearer token per 18239)
svc -> store : keep the final version as "Archived"
svc -> store : remove the active DPP (archive stays)
svc --> agent : 204 SuccessNoContent
group Revocation via CMSM (signed in the SE)
  agent -> reg : initiate revocation
  reg --> agent : sign payload
  agent -> se : sign payload (revocation)
  se --> agent : signature
  agent -> reg : finish revocation (sig)
  reg -> reg : revoke DID, terminate log, publish
  reg --> agent : revoked
end
agent --> client : deleted
note over agent, reg : Only the client (SE) can revoke the DID\n-> no lock-in at the DPP Service
@enduml
```

## What goes onto the data carrier

The `ProductID` — nothing else. prEN 18219 §3.22 defines the unique product
identifier as *one* string that identifies the product and enables the web link
to the passport, and §4.5.2 (1) requires that same string to be retrievable from
the carrier. There is no second token to derive, and no `UPI` field in the
document: prEN 18223 Table 1 defines none.

The registry limits the identifier to **50 characters** over `https` and requires
a direct `200` without a redirect. `CreateDPP` therefore validates the `ProductID`
before anything permanent happens and says how many characters are over.

The host belongs to the **economic operator** and is pointed at the custodian by
a DNS record. That is what lets the passport change custodian without a reprint:
what is printed names the operator, not whoever holds the data.

Two schemes may be borne (see [Identifiers.md](Identifiers.md)): a GS1 Digital
Link, whose path expresses granularity and can therefore be checked instead of
believed, or a self-issued identification link per §5.2 / EN IEC 61406-1, which
needs no issuing agency but says nothing about granularity.

```bash
curl -sS -D - -o /dev/null https://dpp.oydapp.eu/01/09520123456791/21/000123
```

Public, without a token, served by whichever custodian the operator's host
currently points at.

### The legacy short link

Passports created before this design bear an opaque `{base}/p/{short_id}`. Those
links still resolve, because a printed carrier cannot be recalled, but no new
one is issued as a unique product identifier.

```bash
curl -sS -D - -o /dev/null https://r.oydapp.eu/p/cmodBSyBMVHP
```

## Storage in a hosting pod (header `X-DPP-Storage`)

The data intermediary provides pod and collection and records the economic
operator's identity DID as the collection's controller. What is handed over
contains no secret:

```json
{ "base_url": "https://dpp.go-data.at", "collection_id": "4" }
```

The third field is produced by the economic operator, not by the intermediary:
a **delegation**, a JWT signed with the document key of their own `did:oyd`,
naming this service, this pod and exactly one product:

```json
{
  "iss":        "did:oyd:… (the economic operator)",
  "sub":        "did:oyd:… (this service, see /.well-known/dpp-service)",
  "aud":        "https://dpp.go-data.at",
  "collection": "4",
  "product_id": "https://id.lumina.example/01/09520123456788",
  "act":        ["create", "update", "delete"],
  "purpose":    "dpp-hosting",
  "iat": 1786960000, "nbf": 1786960000, "exp": 1794736000,
  "jti": "b2f1c9e4a7d05386"
}
```

The three together go into the header at creation — deliberately as a header and
not as a field of the DPP document, so that the payload stays free of
proprietary attributes (prEN 18223):

```bash
STORAGE='{"base_url":"https://dpp.go-data.at","collection_id":"4","delegation":"'"$DELEGATION"'"}'

curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" \
     -H "X-DPP-Storage: $STORAGE" -d @create-dpp.json
```

Why a signed mandate instead of a password: a `client_secret` never expires,
covers every object of the collection rather than one passport, and has to be
stored by whoever received it. The delegation expires, names one product, can be
revoked by its issuer at the pod, and is worthless to anyone but the service
named in `sub` — which is why this service keeps it in the clear. It presents
the delegation together with two statements of its own (a client assertion and a
DPoP proof) to obtain a ten-minute access token. The full model, including what
the pod verifies, is in `docs/Delegation.md`.

The DID to name in `sub` is published by the service itself:

```bash
curl -sS https://dpp-service.ownyourdata.eu/.well-known/dpp-service | jq .
```

```json
{ "did": "did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd",
  "audience": "https://dpp-service.ownyourdata.eu" }
```

What changes as a result:

| | default (local) | hosting pod |
|---|---|---|
| DPP document and history | database of the DPP Service | in the pod, which archives itself |
| stays local | everything | index, storage configuration, keys |
| carrier host | the operator's own, pointed here by DNS | the operator's own, pointed at the pod |
| DID `serviceEndpoint` | this service | `{base_url}/dpp/v1/dppsByProductId/{ProductID}` |
| public reading | this service | the pod |

The write API stays unchanged. `ReadDPPVersionByProductIdAndDate` is delegated to
the pod for pod-backed DPPs. The header has to be present at `CreateDPP`,
because the serviceEndpoint is frozen when the DID is minted.

## Authentication (prEN 18239)

Reading is public, writing needs a bearer token. How strictly the token is
checked is decided by the environment variable `DPP_AUTH_MODE`:

| | `permissive` (default) | `did` |
|---|---|---|
| signature | is **not** checked | has to be created with the document key of the issuer's `did:oyd` |
| `aud`, `exp` | irrelevant | have to be correct |
| owner | none recorded, anyone may change any passport | only the DID that created the passport may change or delete it |
| purpose | development and trying things out | production |

Which mode an instance runs is shown by an attempt with an unsigned token: if
`201` comes back it runs `permissive`, if `401` comes back it runs in DID mode.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/dpps" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0." -d '{}'
```

### Issuing a token

In DID mode the economic operator issues the token **itself** and signs it with
the key of its own `did:oyd`. There is no central identity provider: the service
resolves the DID, takes the public key from the DID document and verifies the
signature with it. Once the DID is revoked its tokens stop working on their own,
as soon as the cached public key expires (`DID_AUTH_CACHE_TTL`, five minutes by
default).

**Step 1 — create a `did:oyd`.** Most easily over the REST API of the registrar;
this needs neither Docker nor a local Ruby installation:

```bash
curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create \
  -H "Content-Type: application/json" \
  -d '{"didDocument": {"service": [{"type": "DigitalProductPassport",
        "serviceEndpoint": "https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456788"}]},
       "options": {"key_type": "ed25519"}}' | jq .
```

The response contains the identifier and — once only — the private keys:

```json
{
  "didState": {
    "state": "finished",
    "did": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
    "secret": {
      "documentKey": "z1S5Vc8QZXjHQvAZ…",
      "revocationKey": "z1S5SvGY6ctRcNZz…",
      "revocationLog": { "ts": 1786960055, "op": 1, "doc": "zQm…", "sig": "zUW6…" }
    }
  }
}
```

> ⚠️ `documentKey` and `revocationKey` are delivered in this response only and are
> stored nowhere. The `documentKey` signs the tokens, the `revocationKey` revokes
> the DID — keep both safe.

Alternatively with the CLI, which stores the keys as files in the working
directory (`<first-10-characters>_private_key.enc`, `…_revocation_key.enc`):

```bash
echo '{"service":[{
        "type": "DigitalProductPassport",
        "serviceEndpoint": "https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456788"
      }]}' | \
oydid create
```

**Step 2 — sign the token.** Runnable anywhere the `oydid` gem is installed;
`doc_key` is the `documentKey` from step 1 (or the content of the
`_private_key.enc` file):

```ruby
require "oydid"
require "jwt"
require "jwt/eddsa"
require "securerandom"

did     = "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
doc_key = "z1S5Vc8QZXjHQvAZ…"

_code, _len, digest = Oydid.multi_decode(doc_key).first.unpack("SCa*")
signing_key = Ed25519::SigningKey.new(digest)

now = Time.now.to_i
puts JWT.encode({ "iss" => did, "sub" => did,
                  "aud" => "https://dpp-service.ownyourdata.eu",
                  "iat" => now, "exp" => now + 600,
                  "jti" => SecureRandom.hex(8) },
                signing_key, "EdDSA", { "kid" => "#{did}#key-doc" })
```

`require "jwt/eddsa"` is not optional — without this line the `jwt` gem does not
know the EdDSA algorithm and aborts with "Unsupported signing method".

**Step 3 — use it.** The result goes onto every write call as
`Authorization: Bearer …`, nothing else changes.

### The same DID as `did:web`

Every `did:oyd` is also addressable as `did:web` without any extra work — useful
for counterparties that only speak that method:

```bash
curl -sS https://oydid.ownyourdata.eu/zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS/did.json | jq -c '{id, service}'
```

```json
{"id":"did:web:oydid.ownyourdata.eu:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS","service":[{"type":"DigitalProductPassport","serviceEndpoint":"…"}]}
```

It is the same document with the same key, only under a different method name. As
`iss` in the token the service expects the `did:oyd` form.

### Rules the service enforces

From a run on 2026-08-17 against the hosted instance at
`https://dpp-service.ownyourdata.eu` with `DPP_AUTH_MODE=did` — the DID was
created through the registrar's REST API, the token signed with the
`documentKey` returned by it:

```
no token                                      401
unsigned token (alg: none)                    401
validly signed token                          201
tampered signature                            401
expired token                                 401
token with a foreign aud                      401
update by another DID                         403  ClientForbidden
delete by another DID                         403  ClientForbidden
update by the owner                           200
delete by the owner                           204
read without a token                          200
```

Further conditions: `sub` has to equal `iss` (the token is self-issued), `iss`
has to be a DID, and the lifetime may not exceed `DID_AUTH_MAX_LIFETIME`
(default 15 minutes) — without a revocation list a short lifetime is what limits
a token that has gone astray.

The owner is taken from the **verified** token at creation, never from the
payload. It therefore does not appear in the DPP document either:
`EconomicOperatorID` is a business field under the control of the client, whereas
the owner is a determination made by the service.

The first check of a DID takes one to two seconds, because the DID document is
resolved over the network; afterwards the public key is in the cache and the same
DID is checked in around 40 milliseconds. The cache duration
(`DID_AUTH_CACHE_TTL`, default 5 minutes) is at the same time the window in which
a revoked DID is still accepted. This was checked: after `DeleteDPPById` the
service-minted DID no longer resolves through `Oydid.read`, so once the cached
key expires its tokens stop being accepted.

**Still open** is the role model from prEN 18239 — authority, refurbisher,
consumer — and with it the distinction between public data, controlled data and
trade secrets. At the moment there are exactly two levels: publicly readable, and
writable by the owner.

## Examples

End-to-end command-line walkthrough of a Digital Product Passport (DPP)
lifecycle against the DPP Service. Each step is a self-contained section using
`curl` and `jq`.

### Prerequisites

- `curl` and `jq` installed
  for `oydid`: `docker run -it --rm oydeu/oydid-cli` — or use the
  registrar's REST API instead, see *Issuing a token*
- Setup
  - Reading public DPP data needs no token; **creating, updating and deleting**
    require a bearer token.
  > The hosted instance runs `DPP_AUTH_MODE=did`, so this walkthrough needs a
  > **signed** token. Section *Issuing a token* above shows the two steps: mint a
  > `did:oyd` at the registrar, then sign a JWT with the `documentKey` you get
  > back. Keep that snippet as `mint_token.rb` — as printed it mints a token that
  > is valid for ten minutes, and the service refuses anything longer than 15. If
  > a call starts answering `401` halfway through, mint a fresh one and set
  > `TOKEN` again. Against your own instance running `permissive`, the unsigned
  > token `eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.` does the job instead;
  > nothing else in the walkthrough changes.
  ```bash
  BASE="https://dpp-service.ownyourdata.eu/dpp/v1"
  TOKEN="$(ruby mint_token.rb)"

  # Reusable header arrays
  JSON=(-H "Content-Type: application/json")
  AUTH=(-H "Authorization: Bearer $TOKEN")

  # Identifiers (URLs / DIDs) must be percent-encoded into a single path segment.
  # Helper: encode a string for use in a URL path.
  enc() { printf %s "$1" | jq -sRr @uri; }
  ```
  > Everything the walkthrough creates belongs to the DID that signed this token.
  > Another DID gets `403 ClientForbidden` on update and delete — that is the
  > owner binding, not a broken token.

### 1. Health check (`GET /up`)

```bash
curl -sS "https://dpp-service.ownyourdata.eu/up" | jq .
```

* expected response:
  ```json
  { "status": "ok" }
  ```

### Two independent choices

Two things are decided separately, and every combination works:

| | who owns the identifier | where the document lives |
|---|---|---|
| **Variant A** | the service mints a `did:oyd` and keeps its keys | local, or a pod if `X-DPP-Storage` is set |
| **Variant B** | the client supplies the DID, the service holds no key | local, or a pod if `X-DPP-Storage` is set |

The examples below show A local (2a), B local (2b) and B with a hosting pod of
the data intermediary (2c). A with a pod works the same way — add the header to
the 2a call.

### 2a. Create a DPP — Variant A (the service mints the DID)

If the request omits `DigitalProductPassportID`, the service mints a `did:oyd`,
keeps its keys, and returns the DID as the DPP identifier. This is
standard-conformant: `CreateDPP` returns the assigned DPP ID.

<details><summary>request body as <code>create-dpp.json</code></summary>

  ```json=
  {
    "ProductID": "https://id.lumina.example/01/09520123456788",
    "Granularity": "model",
    "DPPSchemaVersion": "prEN 18223:2025",
    "EconomicOperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
    "dataElementCollections": [
      {
        "ElementId": "EnergyPerformance",
        "Name": "Energy performance",
        "DataElements": [
          {
            "@type": "SinglevaluedDataElement",
            "ElementId": "LuminousFlux",
            "Name": "Luminous flux",
            "Value": 806,
            "ValueDataType": "xs:integer",
            "UnitOfMeasure": "lm"
          },
          {
            "@type": "SinglevaluedDataElement",
            "ElementId": "EnergyEfficiencyClass",
            "Name": "Energy efficiency class",
            "Value": "E",
            "ValueDataType": "xs:string"
          }
        ]
      }
    ]
  }
  ```
</details>

```bash=
RESP=$(curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" -d @create-dpp.json)
echo "$RESP" | jq .

DID=$(echo "$RESP" | jq -r '.DigitalProductPassportID')
ENC=$(enc "$DID")
PID=$(echo "$RESP" | jq -r '.ProductID')
echo "DID = $DID"
echo "ProductID = $PID"
```

* expected response (`201 Created`)
  ```json
  {
    "DigitalProductPassportID": "did:oyd:zQmY3j9By89J8rZR7SiewfA2ebNdoBWsx5BmJbD7in4aAsf",
    "ProductID": "https://id.lumina.example/01/09520123456788",
    "Granularity": "model",
    "DPPSchemaVersion": "prEN 18223:2025",
    "DPPStatus": "Active",
    "LastUpdate": "2026-08-16T21:01:58Z",
    "EconomicOperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
    "dataElementCollections": [ "… as submitted …" ]
  }
  ```

The private keys never leave the service and are stored encrypted. They are used
once more, at `DeleteDPPById`, to revoke the DID.

### 2b. Create a DPP — Variant B (the client supplies the DID)

The economic operator mints the identifier itself and keeps the keys. The
service stores the DID as given and holds **no key material**.

The `serviceEndpoint` in the DID document must point at the public read path of
whoever will serve the passport — and it runs over the `ProductID`, never over
the DID itself: the DID is the hash over its own document and therefore cannot
appear inside it.

```bash=
PIDB="https://id.lumina.example/01/09520123456789"

echo '{"service":[{
          "type": "DigitalProductPassport",
          "serviceEndpoint": "https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456789"
        }]}' | \
oydid create
```

```
created did:oyd:zQmdoKmooThp5eYU5a89nSZ6u4veSwJtepykzeY8mcRK9PA
```

Without Docker, the same thing over the registrar's REST API — see
*Issuing a token* above for the response shape:

```bash=
curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create \
  -H "Content-Type: application/json" \
  -d '{"didDocument": {"service": [{"type": "DigitalProductPassport",
        "serviceEndpoint": "https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456789"}]},
       "options": {"key_type": "ed25519"}}' | jq -r '.didState.did'
```

Pass it in the document — nothing else changes:

```bash=
DIDB="did:oyd:zQmdoKmooThp5eYU5a89nSZ6u4veSwJtepykzeY8mcRK9PA"

curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" -d "{
  \"DigitalProductPassportID\": \"$DIDB\",
  \"ProductID\": \"$PIDB\",
  \"Granularity\": \"model\",
  \"DPPSchemaVersion\": \"prEN 18223:2025\",
  \"EconomicOperatorID\": \"did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS\"
}" | jq -c '{DigitalProductPassportID, DPPStatus, ProductID}'
```

* expected response (`201 Created`)
  ```json
  {"DigitalProductPassportID":"did:oyd:zQmdoKmooThp5eYU5a89nSZ6u4veSwJtepykzeY8mcRK9PA","DPPStatus":"Active","ProductID":"https://id.lumina.example/01/09520123456789"}
  ```

A supplied `did:oyd` is checked before it is accepted: it has to resolve, and
the `serviceEndpoint` in its document has to name the host that will serve this
passport. Both are refused with `ClientErrorBadRequest`, and nothing is created.
Neither could be repaired later — the service holds no key for a DID it did not
mint, so it cannot perform the DID update that would move the endpoint.

The same fact shows up at deletion: the service cannot revoke a DID it has no
key for, so the identifier stays valid until the holder revokes it. See step 15.

### 2c. Create a DPP — Variant B with the intermediary's hosting pod

Same as 2b, plus the `X-DPP-Storage` header. The document then lives in the pod,
which also serves the public read paths — so the `serviceEndpoint` of the DID
must point at the pod, and the check above compares it against exactly that
host. Because the `serviceEndpoint` is frozen when the DID is minted, **the
header has to exist before the identifier is created**.

```bash=
PIDC="https://id.lumina.example/01/09520123456790"

echo '{"service":[{
          "type": "DigitalProductPassport",
          "serviceEndpoint": "https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456790"
        }]}' | \
oydid create
```

```
created did:oyd:zQmWdUVpUGY8LdE1PVZUwz8gS7iwa1SfsWVoKx8CsDMFGeD
```

Sign a delegation for this one product. It is signed with the document key of
**your** identity DID — the same key that signs your bearer token, so no new
key management is involved. `sub` is the service DID from
`/.well-known/dpp-service`, `aud` is the pod:

```ruby
require "oydid"
require "jwt"
require "jwt/eddsa"
require "securerandom"

my_did  = "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
doc_key = "z1S5Vc8QZXjHQvAZ…"
service = "did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd"

_code, _len, digest = Oydid.multi_decode(doc_key).first.unpack("SCa*")
now = Time.now.to_i

puts JWT.encode({ "iss" => my_did, "sub" => service,
                  "aud" => "https://dpp.go-data.at",
                  "collection" => "4",
                  "product_id" => "https://id.lumina.example/01/09520123456790",
                  "act" => %w[create update delete],
                  "purpose" => "dpp-hosting",
                  "iat" => now, "nbf" => now, "exp" => now + (90 * 86_400),
                  "jti" => SecureRandom.hex(8) },
                Ed25519::SigningKey.new(digest), "EdDSA",
                { "typ" => "dpp-delegation+jwt", "kid" => "#{my_did}#key-doc" })
```

The `typ` header is not decoration: without it the same JWT could be presented
as a write token or as a client assertion (RFC 8725 §3.11), and every verifier
in this model rejects a foreign `typ`.

Then create the passport:

```bash=
DELEGATION="$(ruby mint_delegation.rb)"
STORAGE="{\"base_url\":\"https://dpp.go-data.at\",\"collection_id\":\"4\",\"delegation\":\"$DELEGATION\"}"
DIDC="did:oyd:zQmWdUVpUGY8LdE1PVZUwz8gS7iwa1SfsWVoKx8CsDMFGeD"

curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" \
  -H "X-DPP-Storage: $STORAGE" -d "{
  \"DigitalProductPassportID\": \"$DIDC\",
  \"ProductID\": \"$PIDC\",
  \"Granularity\": \"model\",
  \"DPPSchemaVersion\": \"prEN 18223:2025\",
  \"EconomicOperatorID\": \"did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS\"
}" | jq -c '{DigitalProductPassportID, DPPStatus, ProductID}'
```

* expected response (`201 Created`)
  ```json
  {"DigitalProductPassportID":"did:oyd:zQmWdUVpUGY8LdE1PVZUwz8gS7iwa1SfsWVoKx8CsDMFGeD","DPPStatus":"Active","ProductID":"https://id.lumina.example/01/09520123456790"}
  ```

The `ProductID` is unchanged by the choice of custodian — that is the point of
it. What differs is who answers it: the operator points `id.lumina.example` at
`dpp.go-data.at` by DNS, and the pod serves the passport under the path the
carrier bears.

Before minting anything the service fetches a token from the pod and checks that
it is reachable — an unreachable pod fails the call with `ServerErrorBadGateway`
instead of leaving a passport that points nowhere. With a client-supplied DID it
additionally resolves that DID and refuses it unless its `serviceEndpoint` names
`dpp.go-data.at`.

### 3. Read a DPP by ID (`ReadDPPById`)

Public, no token required. The identifier is percent-encoded into the path.
Works for all three variants — for a pod-backed passport the service fetches the
document from the pod transparently.

```bash=
curl -sS "$BASE/dpps/$ENC" | jq .
```

### 4. Read a DPP by Product ID (`ReadDPPByProductId`)

Returns the current active DPP for a product. This is also the path the DID
document's `serviceEndpoint` points to.

```bash=
PID="https://id.lumina.example/01/09520123456788"
PENC=$(enc "$PID")

curl -sS "$BASE/dppsByProductId/$PENC" | jq '.DigitalProductPassportID'
```

### 5. Read over the data carrier

The string on the carrier is the `ProductID` itself. Reading it is one request,
no token, no redirect and no resolver — the operator's host is pointed at the
custodian by DNS, and the custodian serves the passport under the path.

`id.lumina.example` in this walkthrough is fictional and resolves nowhere, so
the equivalent call through the API is step 4. Against the deployment recorded
in [verification/](verification/README.md) the carrier read is:

```bash=
curl -sS -D - -o /dev/null https://dpp.oydapp.eu/01/09520123456791/21/000123
```

* expected: `HTTP/2 200` plus `ETag` and `Cache-Control` headers.

Carriers printed before this design bear an opaque short link instead. They keep
resolving:

```bash=
curl -sS -D - -o /dev/null https://r.oydapp.eu/p/cmodBSyBMVHP
```

### 6. Read straight from the pod (variant 2c only)

A pod-backed passport is served by the pod itself, so a consumer who follows the
DID document never touches the DPP Service. All four paths are public:

```bash=
POD="https://dpp.go-data.at"
ENCC=$(enc "$DIDC"); PENCC=$(enc "$PIDC")

curl -sS "$POD/p/mtL3AQmIobGB" | jq -c '{DigitalProductPassportID, DPPStatus}'   # legacy short link
curl -sS "$POD/dpp/v1/dppsByProductId/$PENCC" | jq -c '.DigitalProductPassportID'
curl -sS "$POD/dpp/v1/dpps/$ENCC" | jq -c '.DPPStatus'
curl -sS "$POD/dpp/v1/dpps/$ENCC/collections/EnergyPerformance" | jq -c '{ElementId, Name}'
```

All four answer `200`. The same passport read through the DPP Service returns
the identical document. The carrier path (`/01/…`) is served by the pod too, but
only under the operator's own hostname: the pod compares the request host
against the one recorded with the passport, so asking `dpp.go-data.at` for a
carrier path registered to `id.lumina.example` gives `404`.

### 7. Resolve several Product IDs to DPP IDs (`ReadDPPIdsByProductIds`)

Send an array of product identifiers in the body; get the matching DPP IDs back
(with cursor pagination via `?limit=` / `?cursor=`). This always runs against the
service's own index, also for pod-backed passports.

```bash=
curl -sS -X POST "$BASE/dppsByProductIds?limit=100" "${JSON[@]}" -d '[
  "https://id.lumina.example/01/09520123456788"
]' | jq .
```

* expected response:
  ```json
  {
    "statusCode": "Success",
    "payload": [ "did:oyd:zQmY3j9By89J8rZR7SiewfA2ebNdoBWsx5BmJbD7in4aAsf" ],
    "nextCursor": null
  }
  ```

### 8. Update a DPP (`UpdateDPP`, JSON Merge Patch)

RFC 7396 semantics: only the supplied fields change, `null` removes a field.
The previous version is archived automatically (prEN 18221) — locally in
`dpp_versions`, or in the pod, which keeps every earlier payload under its own
content hash. The DID is not touched in either case; the identifier stays stable.

```bash=
curl -sS -X PATCH "$BASE/dpps/$ENC" \
  -H "Content-Type: application/merge-patch+json" "${AUTH[@]}" \
  -d '{ "FacilityID": "https://id.lumina.example/414/0952012345002" }' \
  | jq '{ FacilityID, LastUpdate }'
```

### 9. Read a Data Element Collection

Fetch a single collection instead of the whole DPP.

```bash=
curl -sS "$BASE/dpps/$ENC/collections/EnergyPerformance" | jq .
```

### 10. Read a single Data Element

Address one element by its absolute ElementId path.

```bash=
curl -sS "$BASE/dpps/$ENC/elements/dataElementCollections/EnergyPerformance/DataElements/LuminousFlux" \
  | jq '{ Value, UnitOfMeasure }'
```
* expected response:
  ```json
  { "Value": 806, "UnitOfMeasure": "lm" }
  ```

### 11. Update a single Data Element (`UpdateDataElement`)

Merge patch on one element — e.g. reclassify the energy efficiency class.

```bash=
curl -sS -X PATCH \
  "$BASE/dpps/$ENC/elements/dataElementCollections/EnergyPerformance/DataElements/EnergyEfficiencyClass" \
  -H "Content-Type: application/merge-patch+json" "${AUTH[@]}" \
  -d '{ "Value": "D" }' | jq '.Value'
```

### 12. Read a historical version by date (`ReadDPPVersionByProductIdAndDate`)

Returns the version that was current at the given instant (ISO 8601, UTC). For a
pod-backed passport the service delegates the lookup to the pod; the call and the
response are identical either way.

```bash=
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sS "$BASE/dppsByProductIdAndDate/$PENC?date=$NOW" | jq '{ DPPStatus, LastUpdate }'
```

### 13. List all versions (variant 2c only, token required)

The pod can enumerate the versions of a passport it stores. Unlike the read
paths this one is **not** public — it needs a token for the collection, and it
only answers for the organisation that owns the object.

> This call is yours, not the service's: the delegation authorises the DPP
> Service to write your passport, it does not authorise you to read the pod's
> management views. Credentials of your own at the pod are therefore still what
> this step uses, and they are unaffected by the changeover — the pod keeps its
> `client_credentials` grant for every application that needs it. How a holder
> should authenticate for their own views once they have an identity DID is an
> open point (`docs/Delegation.md` §16, item 5).

```bash=
POD_TOKEN=$(curl -sS -d grant_type=client_credentials \
                 -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" -d scope=read \
                 -X POST "$POD/oauth/token" | jq -r .access_token)

curl -sS -H "Authorization: Bearer $POD_TOKEN" "$POD/dpp/v1/dpps/$ENCC/versions" | jq .
```

* expected response:
  ```json
  {
    "DigitalProductPassportID": "did:oyd:zQmWdUVpUGY8LdE1PVZUwz8gS7iwa1SfsWVoKx8CsDMFGeD",
    "versions": [
      { "version": 1, "timestamp": "2026-08-16T21:12:41Z", "dri": "zQm…" }
    ]
  }
  ```

Without a token the same call returns `401`.

### 14. Register a DPP at the EU Registry (`registerDPP`)

Client-facing registration method (prEN 18222 Clause 5). The connection to the
EU DPP Registry is currently a placeholder; the call returns a registry
identifier. What gets reported as the unique product identifier is the
`ProductID` itself.

```bash=
curl -sS -X POST "$BASE/registerDPP" "${JSON[@]}" "${AUTH[@]}" -d '{
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "OperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
}' | jq .
```

* expected response:
  ```json
  {
    "statusCode": "SuccessCreated",
    "registryIdentifier": "urn:ec:dpp:registry:9f1c8a2e-…"
  }
  ```

### 15. Delete a DPP (`DeleteDPPById`)

Archives the final version (`DPPStatus: "Archived"`) and removes the active
passport. The call is the same for all variants — what differs is the identifier.

```bash=
curl -sS -o /dev/null -w "delete:      %{http_code}\n" -X DELETE "$BASE/dpps/$ENC" "${AUTH[@]}"
curl -sS -o /dev/null -w "read active: %{http_code}\n" "$BASE/dpps/$ENC"
curl -sS "$BASE/dppsByProductIdAndDate/$PENC?date=$NOW" | jq '.DPPStatus'
```

* expected: `delete: 204`, `read active: 404`, and `"Archived"` — the history
  survives the deletion, as prEN 18221 requires. For a pod-backed passport the
  public paths at the pod answer `404` as well, while the version list from
  step 13 keeps returning every version including the archived one.

**What happens to the identifier:**

| | at `DeleteDPPById` |
|---|---|
| Variant A (2a) | the service revokes the DID with the stored keys, then deletes. Afterwards the DID no longer resolves as `did:oyd`; note the `did:web` bridge limitation mentioned under Assumptions. |
| Variant B (2b, 2c) | the service holds no key and revokes nothing. The DID stays resolvable until its holder revokes it. |

Checked against the running service: after deleting the passport from 2b, its
DID still resolved (`error=0`), while the service-minted DID from 2a did not.
Revoking a client-held DID is the holder's job:

```bash=
oydid revoke "$DIDB"
```

### 16. Change the custodian (`POST /dpps/{id}/custody`)

Beyond the standard's method set. Moves a pod-backed passport to the custodian
named by a new `X-DPP-Storage` mandate: the service reads the document from the
custodian that still holds it, writes it to the new one, and repoints the
passport. No identifier changes — not the `DigitalProductPassportID`, and above
all not the `ProductID`, which is what was printed.

The mandate for the old custodian does not work at the new one: its `aud` is the
old pod's base URL. The move is therefore a separate act, signed by the holder.

```bash=
DELEGATION_B="$(ruby mint_delegation.rb)"
STORAGE_B="{\"base_url\":\"https://dpp.data-vault.eu\",\"collection_id\":\"4\",\"delegation\":\"$DELEGATION_B\"}"

curl -sS -X POST "$BASE/dpps/$ENCC/custody" "${AUTH[@]}" \
  -H "X-DPP-Storage: $STORAGE_B" | jq -c '{DigitalProductPassportID, ProductID, DPPStatus}'
```

* expected: `200`, all three values unchanged.

The previous custodian keeps serving. Releasing it is a second, explicit act
carried out under its own mandate:

```bash=
curl -sS -X POST "$BASE/dpps/$ENCC/custody?release_previous=true" "${AUTH[@]}" \
  -H "X-DPP-Storage: $STORAGE_B" -o /dev/null -w "%{http_code}\n"
```

The overlap is a requirement, not a convenience. What still points at the old
custodian is the operator's DNS record, and it keeps pointing there until its
time-to-live expires everywhere — measured in
[verification/](verification/README.md), where removing the old host too early
failed for 16 of 22 requests from a location with a stale resolver cache.

Two things this does not do. The `serviceEndpoint` in the DID document still
names the old custodian; moving it is a DID update, which only the key holder
can perform. And a delegated mandate can soft-delete but not erase — the
architecture can enforce exit, not forgetting.

## Appendix — Generic status codes (prEN 18222, Table 16)

| Generic code | HTTP |
|---|---|
| `Success` | 200 |
| `SuccessCreated` | 201 |
| `SuccessAccepted` | 202 |
| `SuccessNoContent` | 204 |
| `ClientErrorBadRequest` | 400 |
| `ClientNotAuthorized` | 401 |
| `ClientForbidden` | 403 |
| `ClientErrorResourceNotFound` | 404 |
| `ClientMethodNotAllowed` | 405 |
| `ClientResourceConflict` | 409 |
| `ServerInternalError` | 500 |
| `ServerErrorBadGateway` | 502 |

Failed calls return a Result object (prEN 18222, Table 13), e.g.:

```json
{
  "statusCode": "ClientErrorResourceNotFound",
  "message": [
    {
      "messageType": "Error",
      "text": "Collection not found",
      "correlationId": "0d5a9c31-…",
      "timestamp": "2026-08-16T10:05:33Z"
    }
  ]
}
```

## Not implemented yet

| Topic | State |
|---|---|
| Role model and data classes (prEN 18239) | signature verification and owner binding are implemented; authority/refurbisher/consumer and controlled data are missing |
| DID update per DPP change | the version chain lives in `dpp_versions` or in the pod, not in the OYDID log |
| Signatures over the DPP data (prEN 18246) | the DID is the anchor, no proof is delivered with it |
| W3C Verifiable Credentials as claims | not implemented |
| Connection to the real EU registry | `registerDPP` returns a synthetic identifier |
| Content negotiation (prEN 18216 §5) | JSON only; XML, JSON-LD and HTML are missing |
