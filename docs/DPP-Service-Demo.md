# The DPP Service on the command line

**Technical Integration Meeting, PACE-DPP** — live demo, about 15 minutes.

One question runs through it: *who owns the product passport?* We start with the
most comfortable route, where the service provider does everything, and take
control back in two steps — first over the **keys**, then over the **place the
data is kept**. What stands at the end is a passport readable under a domain of
one's own, whose identifier belongs to the economic operator and whose data sits
with a registered data intermediary.

Every command runs against the production deployment.

Two helper scripts under `tmp/` mint the token and the delegation. They sign
with the economic operator's private key and are therefore not part of this
repository — any other signing environment does the same job, and the format is
in `docs/Delegation.md`.

| | |
|---|---|
| DPP Service | `https://dpp-service.ownyourdata.eu` |
| Custodian (data intermediary) | `https://dpp.go-data.at`, collection 36 |
| Economic operator's domain | `dpp.oydapp.eu` |
| VDR / registrar for `did:oyd` | `https://oydid.ownyourdata.eu` |

> **About the names.** Those four lines are four **roles**, not four products of
> the same house. `dpp.oydapp.eu` is the economic operator's domain — it belongs
> to the operator, not to the service, and the service has no access to it. That
> the same organisation happens to stand behind several of these roles is the one
> simplification in this demo; the separation at issue is real all the same, and
> it is checkable at every point below where one hostname is compared with
> another.

**Who holds what.** Three actors, and in every step it shifts which of them has
which information. The same sketch appears again after steps 1, 3 and 5; `▸`
marks what that step changed.

```
┌─ ECONOMIC OPERATOR ────────────────────── dpp.oydapp.eu ─┐
│ Identity key  ·  DNS zone                                │
│ Passport keys, as soon as it mints them itself           │
└──────────────────────────────────────────────────────────┘
        │  Token, self-issued
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadata per passport  ·  Delegation in the clear        │
│ Payload only while no custodian is named                 │
└──────────────────────────────────────────────────────────┘
        │  Delegation in the X-DPP-Storage header
        ▼
┌─ CUSTODIAN (intermediary) ────────────── dpp.go-data.at ─┐
│ Payload  ·  History  ·  Access log                       │
│ knows the passport as an object, not as a passport       │
└──────────────────────────────────────────────────────────┘
```

---

## 0 — Preparation

```bash
cd ~/projects/pace-dpp/impl/dpp-service
BASE="https://dpp-service.ownyourdata.eu/dpp/v1"
EO="did:oyd:zQmX493GLVxE8Wasc8ANTdZmq4YUsvdk5j6Daf7iQaPECt6"
curl -sS -o /dev/null -w 'Service: %{http_code}\n' https://dpp-service.ownyourdata.eu/up
curl -sS https://dpp-service.ownyourdata.eu/.well-known/dpp-service | jq .
```

Expected:

```json
{
  "did": "did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd",
  "audience": "https://dpp-service.ownyourdata.eu"
}
```

> The service says publicly who it is. That DID is what a delegation is later
> issued to — and it is the reason no shared secret is needed.

**The token.** Writes need a bearer token that the economic operator **issues to
itself** and signs with its identity key. There is no registration and no
password handed out by the service.

```bash
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
echo "$TOKEN" | cut -d. -f2 | ruby -rbase64 -e 's = STDIN.read.strip; print Base64.urlsafe_decode64(s + "=" * ((4 - s.size % 4) % 4))' | jq .
```

Expected: `iss` and `sub` are the economic operator's DID, `aud` is the service.

> Tokens are short-lived — which is why this line appears again before every
> write.

> **Worth remembering:** this is the economic operator's *identity key*. The
> *passport key* is something else, and we do not have one yet.

---

## 1 — The comfortable route: the service does everything

We create a passport and supply **no** passport identifier and **no** storage
location.

```bash
PID1="https://dpp.oydapp.eu/01/09520123456788/21/000901"
curl -sS -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d @- <<JSON | jq .
{
  "uniqueProductIdentifier": "$PID1",
  "granularity": "item",
  "dppSchemaVersion": "EN 18223:2026",
  "economicOperatorId": "$EO",
  "elements": [
    { "elementId": "ProductIdentification",
      "objectType": "DataElementCollection",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "ModelIdentifier", "value": "LUM-A60-827-806", "valueDataType": "xsd:string" },
        { "objectType": "SingleValuedDataElement", "elementId": "BrandName", "value": "Lumina", "valueDataType": "xsd:string" }
      ] }
  ]
}
JSON
```

Expected: `201`, and the answer carries a **freshly minted**
`digitalProductPassportId` — the service made it, not us.

Two identifiers are now in play, and it is worth showing right here how they
relate:

```
   Data carrier (QR, NFC)
        │   carries EXACTLY ONE string
        ▼
   uniqueProductIdentifier   https://dpp.oydapp.eu/01/09520123456788/21/000901
        │                      └─ host: economic operator
        │                                   └─ path: scheme A or B
        │   DNS record, no redirect
        ▼
   Custodian           in step 1 still the service itself
        ▼
   Passport document   uniqueProductIdentifier · digitalProductPassportId ─▶ ①
        │              economicOperatorId ──▶ ②  ·  facilityId
        │              granularity · dppSchemaVersion · dppStatus · lastUpdated
        │   DID resolution
        ▼
   DID documents       ① passport: serviceEndpoint, publicKeyMultibase
                       ② operator: publicKeyMultibase
```

**The product identifier is the address, the passport identifier is the
identity.** Reading goes through the address — one scan, no resolver, no
redirect. Everything that assigns responsibility — writing, delegating,
revoking, versioning — hangs on the identity.

It can be read straight away:

```bash
ENC1=$(printf %s "$PID1" | jq -sRr @uri)
curl -sS "$BASE/dppsByProductId/$ENC1" | jq -c 'if .digitalProductPassportId then {digitalProductPassportId, uniqueProductIdentifier, granularity, dppStatus} else . end'
```

### What we gave away in the process

```bash
DID1=$(curl -sS "$BASE/dppsByProductId/$ENC1" | jq -r .digitalProductPassportId)
curl -sS "https://oydid.ownyourdata.eu/1.0/identifiers/$DID1" | jq -c '.service[0].serviceEndpoint'
curl -sS -o /dev/null -w 'Carrier under our own domain: %{http_code}\n' "$PID1"
```

Expected: the `serviceEndpoint` points at **`dpp-service.ownyourdata.eu`**, and
the carrier under our own domain answers **404**.

> **One dependency, two consequences.**
> 1. The passport identifier was minted by the service — it holds `documentKey`
>    and `revocationKey`. It can revoke the identifier and change the DID
>    document; the economic operator can do neither in this configuration.
> 2. Which also settles where a reader is sent: the `serviceEndpoint` points at
>    the service, and only whoever holds the key can redirect it.
>
> The 404 under our own domain shows only that nothing is being served there
> **at the moment** — not that nothing may be. The data belongs to the economic
> operator, and nobody stops it from publishing that data under its own domain.
> What it cannot do without the service is make that publication the *passport*:
> nothing signs it, no history hangs on it, and whoever resolves the passport
> identifier still ends up at the service.
>
> The practical price: leaving, in this variant, takes either the service's
> cooperation or a new passport identifier. The printed carrier survives that;
> the identity does not.

**Where things stand after this step.**

```
┌─ ECONOMIC OPERATOR ────────────────────── dpp.oydapp.eu ─┐
│ Identity key                                             │
└──────────────────────────────────────────────────────────┘
        │  Token
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadata per passport                                    │
│ ▸ Passport identifier, documentKey, revocationKey        │
│ ▸ Payload                                                │
└──────────────────────────────────────────────────────────┘
        ·  custodian not involved yet
```

---

## 2 — Interlude: the two identifiers

The sketch from step 1 as a table — the same distinction, sorted by property:

| | Product identifier | Passport identifier |
|---|---|---|
| identifies | the product | the document about it |
| appears on the carrier | yes | never |
| changes | never, once printed | with every change to the document |
| carries keys | no | yes — signing, revoking, versioning |
| needed for | reading | writing, registry, backup copy, history |

> Why the `serviceEndpoint` goes through the product identifier: a `did:oyd` is
> the hash over its own document. An address containing the DID would be part of
> its own computation.
>
> And why both are needed: EN 18222 cl. 4.5 returns a **list** of passport
> identifiers (`0..*`) for one product identifier — the backup copy required by
> ESPR Art. 10(4) is the everyday case.

---

## 3 — Control over the keys: our own passport identifier

We mint the passport identifier ourselves, at the VDR, and keep both keys. What
matters is the `serviceEndpoint`: it has to name the host that will **actually
serve** the passport — here still the service itself.

```bash
PID2="https://dpp.oydapp.eu/01/09520123456788/21/000902"
ENC2=$(printf %s "$PID2" | jq -sRr @uri)
RESP=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/$ENC2\"}]},\"options\":{\"key_type\":\"ed25519\"}}")
DID2=$(echo "$RESP" | jq -r '.didState.did')
echo "$RESP" | jq '.didState.secret'
echo "DID2 = $DID2"
```

> ⚠️ `documentKey` and `revocationKey` come back **in this one answer** and are
> stored nowhere. Whoever keeps them owns the identifier.

Now create the passport with it — the service mints nothing any more:

```bash
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d @- <<JSON | jq -c 'if .digitalProductPassportId then {digitalProductPassportId, uniqueProductIdentifier, dppStatus} else . end'
{
  "digitalProductPassportId": "$DID2",
  "uniqueProductIdentifier": "$PID2",
  "granularity": "item",
  "dppSchemaVersion": "EN 18223:2026",
  "economicOperatorId": "$EO",
  "elements": [
    { "elementId": "ProductIdentification",
      "objectType": "DataElementCollection",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "ModelIdentifier", "value": "LUM-A60-827-806", "valueDataType": "xsd:string" }
      ] }
  ]
}
JSON
```

Expected: `201`, and the **supplied identifier comes back unchanged**.

### The check that runs while it happens

The service holds no key for a DID it did not mint — so it could never repair a
wrong DID document later. It therefore checks, **before** anything permanent
happens, that the identifier resolves and that its `serviceEndpoint` names the
right host. Deliberately wrong, to show it:

```bash
PIDX="https://dpp.oydapp.eu/01/09520123456788/21/000999"
ENCX=$(printf %s "$PIDX" | jq -sRr @uri)
DIDX=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"https://dpp.data-vault.eu/dpp/v1/dppsByProductId/$ENCX\"}]},\"options\":{\"key_type\":\"ed25519\"}}" | jq -r '.didState.did')
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -w '\nHTTP %{http_code}\n' -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d "{\"digitalProductPassportId\":\"$DIDX\",\"uniqueProductIdentifier\":\"$PIDX\",\"granularity\":\"item\",\"dppSchemaVersion\":\"EN 18223:2026\",\"economicOperatorId\":\"$EO\"}"
```

Expected: **`HTTP 400`**, and the message names **both** hostnames in plain text:

```
digitalProductPassportId resolves to dpp.data-vault.eu,
but this passport is served from dpp-service.ownyourdata.eu
```

Nothing is created. Only the **host** is compared, never the path — what is
under examination is where a reader is sent.

**Where things stand after this step.**

```
┌─ ECONOMIC OPERATOR ────────────────────── dpp.oydapp.eu ─┐
│ Identity key                                             │
│ ▸ documentKey and revocationKey of the passport          │
└──────────────────────────────────────────────────────────┘
        │  Token  +  ready-made passport identifier
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadata per passport  ·  Payload                        │
│ ▸ no key to the passport identifier                      │
└──────────────────────────────────────────────────────────┘
        ·  custodian not involved yet
```

---

## 4 — Control over the storage: intermediary and DNS

Two things are needed, and they are independent of each other.

**First the name.** `dpp.oydapp.eu` belongs to the economic operator and points
by DNS at the custodian:

```bash
dig +short dpp.oydapp.eu
```

Expected: `89.58.20.114` — the custodian's address. The custodian therefore
serves under a name that is **not its own**. Nothing is redirected; a change of
custodian is a record in one's own zone, not a reprint.

**Second the delegation.** The economic operator issues and signs it itself; it
names the delegate, the custodian, the collection, the product, the permitted
operations and the purpose. The service passes it on in the `X-DPP-Storage`
header — **not** as a field in the passport, because a proprietary attribute in
the document would break EN 18223 conformance for every reader.

```bash
PID3="https://dpp.oydapp.eu/01/09520123456788/21/000903"
DELEG=$(SERVICE_DID="did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd" POD_BASE="https://dpp.go-data.at" COLLECTION_ID=36 PRODUCT_ID="$PID3" bundle exec ruby tmp/mint_delegation.rb 2>/dev/null)
STORAGE="{\"base_url\":\"https://dpp.go-data.at\",\"collection_id\":\"36\",\"delegation\":\"$DELEG\"}"
echo "$DELEG" | cut -d. -f2 | ruby -rbase64 -e 's = STDIN.read.strip; print Base64.urlsafe_decode64(s + "=" * ((4 - s.size % 4) % 4))' | jq .
```

Expected: the content of the delegation in plain text — issuer, delegate,
custodian, collection, product, purpose, lifetime, replay identifier.

> What the service stores is therefore **no longer an access key**. The
> delegation names its delegate explicitly and is inert without that delegate's
> private key. A provider working for many economic operators would otherwise
> hold one secret per customer.

---

## 5 — Everything together

Our own identifier, our own name, storage at the intermediary. The
`serviceEndpoint` now names the long form **at the custodian**.

```bash
ENC3=$(printf %s "$PID3" | jq -sRr @uri)
RESP3=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"https://dpp.go-data.at/dpp/v1/dppsByProductId/$ENC3\"}]},\"options\":{\"key_type\":\"ed25519\"}}")
DID3=$(echo "$RESP3" | jq -r '.didState.did')
echo "$RESP3" | jq '.didState.secret'
echo "DID3 = $DID3"
```

```bash
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-DPP-Storage: $STORAGE" -d @- <<JSON | jq -c 'if .digitalProductPassportId then {digitalProductPassportId, uniqueProductIdentifier, granularity, dppStatus} else . end'
{
  "digitalProductPassportId": "$DID3",
  "uniqueProductIdentifier": "$PID3",
  "granularity": "item",
  "dppSchemaVersion": "EN 18223:2026",
  "economicOperatorId": "$EO",
  "elements": [
    { "elementId": "ProductIdentification",
      "objectType": "DataElementCollection",
      "dictionaryReference": "https://dict.example.org/dpp/lighting/ProductIdentification",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "ModelIdentifier", "value": "LUM-A60-827-806", "valueDataType": "xsd:string" },
        { "objectType": "SingleValuedDataElement", "elementId": "BrandName", "value": "Lumina", "valueDataType": "xsd:string" },
        { "objectType": "SingleValuedDataElement", "elementId": "SerialNumber", "value": "000903", "valueDataType": "xsd:string" }
      ] },
    { "elementId": "EnergyPerformance",
      "objectType": "DataElementCollection",
      "dictionaryReference": "https://dict.example.org/dpp/lighting/EnergyPerformance",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "OnModePower", "value": 8.5, "valueDataType": "xsd:decimal", "unitOfMeasure": "W" },
        { "objectType": "SingleValuedDataElement", "elementId": "LuminousFlux", "value": 806, "valueDataType": "xsd:integer", "unitOfMeasure": "lm" }
      ] }
  ]
}
JSON
```

### The moment the whole demo builds up to

```bash
curl -sS "https://dpp.oydapp.eu/01/09520123456788/21/000903" | jq .
```

**One request. No token, no resolution service, no redirect.** Exactly the string
printed on the product returns the passport — which is what EN 18219:2026
cl. 4.5.2 (1) requires.

And the three checks, each provable on its own:

```bash
echo "--- the identifier is ours: the service did not mint it ---"
curl -sS "https://oydid.ownyourdata.eu/1.0/identifiers/$DID3" | jq -c '.service[0].serviceEndpoint'
echo "--- both serve it, but only one stores it ---"
curl -sS -o /dev/null -w 'Custodian: %{http_code}\n' "https://dpp.go-data.at/dpp/v1/dppsByProductId/$ENC3"
curl -sS -o /dev/null -w 'Service:   %{http_code}\n' "$BASE/dppsByProductId/$ENC3"
echo "--- and the custodian does NOT serve under its own name ---"
curl -sS -o /dev/null -w 'same path at dpp.go-data.at: %{http_code}\n' "https://dpp.go-data.at/01/09520123456788/21/000903"
```

Expected: the `serviceEndpoint` names the custodian; **both** answer `200`; and
the carrier path under the custodian's own name `404`.

> That the service answers `200` as well is no contradiction: for a passport held
> at a custodian it does not keep the content, it reads it there on every access
> (`Dpp#document_content` → `pod_storage.read_payload`). It stays a pass-through
> — take the delegation away and it has nothing left to serve.

> The last line is the important one: the path is the lookup key, but the host
> has to be the economic operator's. Otherwise a custodian could serve the
> passport under its own domain and quietly make itself the address on the
> product.

**Where things stand after this step.**

```
┌─ ECONOMIC OPERATOR ────────────────────── dpp.oydapp.eu ─┐
│ Identity key  ·  Passport keys                           │
│ ▸ DNS zone points at the custodian                       │
└──────────────────────────────────────────────────────────┘
        │  Token  +  passport identifier  +  delegation
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadata per passport  ·  Delegation in the clear        │
│ ▸ no payload any more, reads it through                  │
└──────────────────────────────────────────────────────────┘
        │  Delegation in the X-DPP-Storage header
        ▼
┌─ CUSTODIAN ───────────────────────────── dpp.go-data.at ─┐
│ ▸ Payload  ·  History  ·  Access log                     │
│ knows the passport as an object                          │
└──────────────────────────────────────────────────────────┘
```

---

## 6 — Cleaning up, and the difference becomes visible

```bash
E1=$(printf %s "$DID1" | jq -sRr @uri)
E3=$(printf %s "$DID3" | jq -sRr @uri)
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -o /dev/null -w 'Delete passport 1: %{http_code}\n' -X DELETE "$BASE/dpps/$E1" -H "Authorization: Bearer $TOKEN"
curl -sS -o /dev/null -w 'Delete passport 3: %{http_code}\n' -X DELETE "$BASE/dpps/$E3" -H "Authorization: Bearer $TOKEN"
echo "--- and what about the identifiers? ---"
curl -sS -o /dev/null -w 'DID from step 1 (service held the key): %{http_code}\n' "https://oydid.ownyourdata.eu/1.0/identifiers/$DID1"
curl -sS -o /dev/null -w 'DID from step 5 (we hold the key):      %{http_code}\n' "https://oydid.ownyourdata.eu/1.0/identifiers/$DID3"
```

Expected: `204` for both passports. The identifier the service minted is
**revoked** (`410`); our own one **still resolves** (`200`).

> The service cannot revoke what it holds no key for. That is not a gap but the
> point: **the architecture can compel departure, not forgetting.**

---

## Appendix — failure modes, for questions from the floor

| Situation | Answer |
|---|---|
| identifier does not resolve | `400` `… does not resolve` |
| `serviceEndpoint` names a different host | `400`, both hostnames in plain text |
| declared granularity contradicts the path | `400` `granularity 'model' contradicts the identifier path, which expresses 'item'` |
| identifier longer than 50 characters | `400`, stating by how much |
| no token, or an invalid one | `401 ClientNotAuthorized` |
| a foreign DID tries to write | `403 ClientForbidden` |
| public reading | never needs a token |

**What deliberately does not appear here:** no `client_secret`, no password
handed out by the service, no registration with the custodian, no query to the
EU registry when reading. Everything that grants access is a statement signed by
the holder, with a limited lifetime.

**What is not possible today:** the graduated read rights for restricted data
(authorities, recyclers) are specified but not deployed — this demo shows the
public layer. And binding the *content* to the identifier, which would keep even
the custodian from changing anything unnoticed, is designed and not yet in
operation; today the **place** is cryptographically bound, not the content.

---

*Evidence for every claim above: `github.com/OwnYourData/dpp-service-public`,
v3.0.0, `doi:10.5281/zenodo.22117494`, under `docs/verification/`.*
