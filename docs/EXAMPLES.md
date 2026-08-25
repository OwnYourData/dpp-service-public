# DPP Service — Examples

End-to-end command-line walkthrough of a Digital Product Passport (DPP)
lifecycle against the DPP Service. Each step is a self-contained section using
`curl` and `jq`.

The service implements the REST/HTTPS mappings of **prEN 18222**; the payload
model follows **prEN 18223**; identifiers may be W3C DIDs (**prEN 18219**,
`did:oyd`). All paths are prefixed with `/dpp/v1`.

## Prerequisites

- `curl` and `jq` installed.
- Reading public DPP data needs no token; **creating, updating and deleting**
  require a bearer token.

> The hosted instance runs `DPP_AUTH_MODE=did`: the bearer token has to be a
> self-issued JWT, EdDSA-signed with the document key of the issuer's
> `did:oyd`, and only the DID that created a passport may update or delete it.
> *Issuing a token* below shows how to mint the DID and sign the token; keep
> that snippet as `mint_token.rb`. The unsigned token in the setup block is the
> fallback for your own instance running `permissive`, where the signature is
> not checked.

## Issuing a token

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

## Setup

```bash
BASE="https://dpp-service.ownyourdata.eu/dpp/v1"
TOKEN="$(ruby mint_token.rb)"
# permissive instances only — an unsigned token, built on the spot:
# b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# TOKEN="$(printf '{"alg":"none"}' | b64).$(printf '{"sub":"did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS","scope":"dpp:write"}' | b64)."

# Reusable header arrays
JSON=(-H "Content-Type: application/json")
AUTH=(-H "Authorization: Bearer $TOKEN")

# Identifiers (URLs / DIDs) must be percent-encoded into a single path segment.
# Helper: encode a string for use in a URL path.
enc() { printf %s "$1" | jq -sRr @uri; }
```

---

## 1. Health check

```bash
curl -sS "https://dpp-service.ownyourdata.eu/up" | jq .
```

Expected:

```json
{ "status": "ok" }
```

---

## 2a. Create a DPP — the service mints the identifier

Three ways to get a passport identifier, side by side. **2a** lets the service
mint it, **2b** has the economic operator mint it and keep the key, **2c**
supplies an identifier that is not a DID at all. They are alternatives, not a
sequence — from step 3 onwards everything is the same, whichever you chose.

If the request omits `DigitalProductPassportID`, the service mints a `did:oyd`,
keeps its keys, and returns the DID as the DPP identifier. This is standard-
conformant: `CreateDPP` returns the assigned DPP ID.

Save the request body as `create-dpp.json`:

```json
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

Create the DPP and capture the minted DID:

```bash
RESP=$(curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" -d @create-dpp.json)
echo "$RESP" | jq .

DID=$(echo "$RESP" | jq -r '.DigitalProductPassportID')
ENC=$(enc "$DID")
echo "DID = $DID"
```

Expected response (`201 Created`) — note the DID has **no** `@location` suffix
when the default repository is used:

```json
{
  "DigitalProductPassportID": "did:oyd:zQmExampleHash123",
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "Granularity": "model",
  "DPPSchemaVersion": "prEN 18223:2025",
  "DPPStatus": "Active",
  "LastUpdate": "2026-08-03T09:14:02Z",
  "EconomicOperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
  "dataElementCollections": [ "… as submitted …" ]
}
```

---

## 2b. Create a DPP — the operator mints the identifier and keeps the key

Here the economic operator mints the passport DID **before** creating the
passport and keeps both keys. The service stores the identifier and holds no key
material for it, so it can neither update the DID document nor revoke it. That
is the point: the identifier belongs to the operator, not to whoever runs the
service.

Two things have to be right at this moment, because neither can be repaired
afterwards. The `serviceEndpoint` in the DID document has to name the host that
will serve this passport — this service, or the custodian's base URL when the
passport goes into a hosting pod. And the endpoint goes through the `ProductID`,
percent-encoded, rather than through the DID: a `did:oyd` is the hash over its
own document, so an address containing the DID would be part of its own
computation.

```bash
PIDB="https://id.lumina.example/01/09520123456789"
ENDPOINT="https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/$(enc "$PIDB")"

RESPB=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create \
  -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"$ENDPOINT\"}]},\"options\":{\"key_type\":\"ed25519\"}}")

DIDB=$(echo "$RESPB" | jq -r '.didState.did')
echo "$RESPB" | jq '.didState.secret'
echo "DIDB = $DIDB"
```

> ⚠️ `documentKey` and `revocationKey` come back in that one answer and are
> stored nowhere. They are what makes this variant what it is — keep them, and
> the passport identifier stays yours. The same `documentKey` can sign the
> bearer token; see *Issuing a token* above.

Then create the passport with it; nothing else changes:

```bash
curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" -d "{
  \"DigitalProductPassportID\": \"$DIDB\",
  \"ProductID\": \"$PIDB\",
  \"Granularity\": \"model\",
  \"DPPSchemaVersion\": \"prEN 18223:2025\",
  \"EconomicOperatorID\": \"did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS\"
}" | jq -c '{DigitalProductPassportID, ProductID, DPPStatus}'
```

Expected (`201 Created`) — the identifier comes back exactly as supplied:

```json
{"DigitalProductPassportID":"did:oyd:zQmExampleHashB456","ProductID":"https://id.lumina.example/01/09520123456789","DPPStatus":"Active"}
```

A supplied `did:oyd` is resolved before anything is created, and refused with
`400 ClientErrorBadRequest` in two cases:

| What is wrong | What the answer says |
|---|---|
| the DID does not resolve | `did:oyd:… does not resolve` |
| its `serviceEndpoint` names a different host | `DigitalProductPassportID resolves to other.example, but this passport is served from dpp-service.ownyourdata.eu` |

Only the host is compared, never the path — the path carries the `ProductID`,
and what is being checked is where a reader is sent.

The consequence shows up at deletion: the service cannot revoke a DID it holds
no key for, so the identifier stays valid until you revoke it yourself with
`oydid revoke "$DIDB"`. See step 12.

---

## 2c. Create a DPP — an identifier that is not a DID

`DigitalProductPassportID` may also be an ordinary URL. The service stores it
as-is, mints nothing, and resolves nothing: the check in 2b applies to
`did:oyd`, which the service can resolve, not to identifiers in general.

```bash
curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" -d '{
  "DigitalProductPassportID": "https://dpp-service.ownyourdata.eu/01/09520123456788/0001",
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "Granularity": "model",
  "DPPSchemaVersion": "prEN 18223:2025",
  "EconomicOperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
}' | jq '.DigitalProductPassportID'
```

Whatever you supply here is what readers will use. It is not the string on the
data carrier — that is the `ProductID`, and it stays the same in all three
variants.

---

## 3. Read a DPP by ID (ReadDPPById)

Public, no token required. The identifier is percent-encoded into the path.

```bash
curl -sS "$BASE/dpps/$ENC" | jq .
```

---

## 4. Read a DPP by Product ID (ReadDPPByProductId)

Returns the current active DPP for a product.

```bash
PID="https://id.lumina.example/01/09520123456788"
PENC=$(enc "$PID")

curl -sS "$BASE/dppsByProductId/$PENC" | jq '.DigitalProductPassportID'
```

---

## 5. Resolve several Product IDs to DPP IDs (ReadDPPIdsByProductIds)

Send an array of product identifiers in the body; get the matching DPP IDs back
(with cursor pagination via `?limit=` / `?cursor=`).

```bash
curl -sS -X POST "$BASE/dppsByProductIds?limit=100" "${JSON[@]}" -d '[
  "https://id.lumina.example/01/09520123456788"
]' | jq .
```

Expected:

```json
{
  "statusCode": "Success",
  "payload": [ "did:oyd:zQmExampleHash123" ],
  "nextCursor": null
}
```

---

## 6. Update a DPP (UpdateDPP, JSON Merge Patch)

RFC 7396 semantics: only the supplied fields change, `null` removes a field.
The previous version is archived automatically (prEN 18221).

```bash
curl -sS -X PATCH "$BASE/dpps/$ENC" \
  -H "Content-Type: application/merge-patch+json" "${AUTH[@]}" \
  -d '{ "FacilityID": "https://id.lumina.example/414/0952012345002" }' \
  | jq '{ FacilityID, LastUpdate }'
```

---

## 7. Read a Data Element Collection

Fetch a single collection instead of the whole DPP.

```bash
curl -sS "$BASE/dpps/$ENC/collections/EnergyPerformance" | jq .
```

---

## 8. Read a single Data Element

Address one element by its absolute ElementId path.

```bash
curl -sS "$BASE/dpps/$ENC/elements/dataElementCollections/EnergyPerformance/DataElements/LuminousFlux" \
  | jq '{ Value, UnitOfMeasure }'
```

Expected:

```json
{ "Value": 806, "UnitOfMeasure": "lm" }
```

---

## 9. Update a single Data Element (UpdateDataElement)

Merge patch on one element — e.g. reclassify the energy efficiency class.

```bash
curl -sS -X PATCH \
  "$BASE/dpps/$ENC/elements/dataElementCollections/EnergyPerformance/DataElements/EnergyEfficiencyClass" \
  -H "Content-Type: application/merge-patch+json" "${AUTH[@]}" \
  -d '{ "Value": "D" }' | jq '.Value'
```

---

## 10. Read a historical version by date (ReadDPPVersionByProductIdAndDate)

Returns the version that was current at the given instant (ISO 8601, UTC).

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sS "$BASE/dppsByProductIdAndDate/$PENC?date=$NOW" | jq '{ DPPStatus, LastUpdate }'
```

---

## 11. Register a DPP at the EU Registry (registerDPP)

Client-facing registration method (prEN 18222 Clause 5). The connection to the
EU DPP Registry is currently a placeholder; the call returns a registry
identifier.

```bash
curl -sS -X POST "$BASE/registerDPP" "${JSON[@]}" "${AUTH[@]}" -d '{
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "OperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
}' | jq .
```

Expected:

```json
{
  "statusCode": "SuccessCreated",
  "registryIdentifier": "urn:ec:dpp:registry:9f1c8a2e-…"
}
```

---

## 12. Delete a DPP (DeleteDPPById)

Archives the final version (`DPPStatus: "Archived"`) and removes the active
passport. For a service-minted DID (2a) the DID is **revoked** first; for one
you minted yourself (2b) the service holds no key and revokes nothing.

```bash
# Delete (expect 204)
curl -sS -o /dev/null -w "delete:      %{http_code}\n" -X DELETE "$BASE/dpps/$ENC" "${AUTH[@]}"

# The active DPP is gone (expect 404)
curl -sS -o /dev/null -w "read active: %{http_code}\n" "$BASE/dpps/$ENC"

# The archived version is still retrievable by date
curl -sS "$BASE/dppsByProductIdAndDate/$PENC?date=$NOW" | jq '.DPPStatus'
```

---

## Appendix — Generic status codes (prEN 18222, Table 16)

| Generic code | HTTP |
|---|---|
| `Success` | 200 |
| `SuccessCreated` | 201 |
| `SuccessNoContent` | 204 |
| `ClientErrorBadRequest` | 400 |
| `ClientNotAuthorized` | 401 |
| `ClientForbidden` | 403 |
| `ClientErrorResourceNotFound` | 404 |
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
      "timestamp": "2026-08-03T10:05:33Z"
    }
  ]
}
```
