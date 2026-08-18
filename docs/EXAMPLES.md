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

> Since 2026-08-17 the hosted instance runs `DPP_AUTH_MODE=did`: the bearer
> token has to be a self-issued JWT, EdDSA-signed with the document key of the
> issuer's `did:oyd`, and only the DID that created a passport may update or
> delete it. `docs/Guide.md`, section *Issuing a token*, shows how to mint the
> DID and sign the token; keep that snippet as `mint_token.rb`. The unsigned
> token below is the fallback for your own instance running `permissive`, where
> the signature is not checked.

## Setup

```bash
BASE="https://dpp-service.ownyourdata.eu/dpp/v1"
TOKEN="$(ruby mint_token.rb)"
# permissive instances only:
# TOKEN="eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6b3lkOnpRbVBQd0hKSzFOSEJ6M0JTODlTdFdzZnJINHB6a3lxd0ppSzk0elZqMjV3WFVTIiwic2NvcGUiOiJkcHA6d3JpdGUifQ."

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

## 2. Create a DPP — Variant A (the service mints the DID)

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

## 3. Create a DPP with a client-supplied identifier

If `DigitalProductPassportID` is present, the service stores it as-is and does
**not** mint a DID.

```bash
curl -sS -X POST "$BASE/dpps" "${JSON[@]}" "${AUTH[@]}" -d '{
  "DigitalProductPassportID": "https://dpp-service.ownyourdata.eu/01/09520123456788/0001",
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "Granularity": "model",
  "DPPSchemaVersion": "prEN 18223:2025",
  "EconomicOperatorID": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
}' | jq '.DigitalProductPassportID'
```

---

## 4. Read a DPP by ID (ReadDPPById)

Public, no token required. The identifier is percent-encoded into the path.

```bash
curl -sS "$BASE/dpps/$ENC" | jq .
```

---

## 5. Read a DPP by Product ID (ReadDPPByProductId)

Returns the current active DPP for a product.

```bash
PID="https://id.lumina.example/01/09520123456788"
PENC=$(enc "$PID")

curl -sS "$BASE/dppsByProductId/$PENC" | jq '.DigitalProductPassportID'
```

---

## 6. Resolve several Product IDs to DPP IDs (ReadDPPIdsByProductIds)

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

## 7. Update a DPP (UpdateDPP, JSON Merge Patch)

RFC 7396 semantics: only the supplied fields change, `null` removes a field.
The previous version is archived automatically (prEN 18221).

```bash
curl -sS -X PATCH "$BASE/dpps/$ENC" \
  -H "Content-Type: application/merge-patch+json" "${AUTH[@]}" \
  -d '{ "FacilityID": "https://id.lumina.example/414/0952012345002" }' \
  | jq '{ FacilityID, LastUpdate }'
```

---

## 8. Read a Data Element Collection

Fetch a single collection instead of the whole DPP.

```bash
curl -sS "$BASE/dpps/$ENC/collections/EnergyPerformance" | jq .
```

---

## 9. Read a single Data Element

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

## 10. Update a single Data Element (UpdateDataElement)

Merge patch on one element — e.g. reclassify the energy efficiency class.

```bash
curl -sS -X PATCH \
  "$BASE/dpps/$ENC/elements/dataElementCollections/EnergyPerformance/DataElements/EnergyEfficiencyClass" \
  -H "Content-Type: application/merge-patch+json" "${AUTH[@]}" \
  -d '{ "Value": "D" }' | jq '.Value'
```

---

## 11. Read a historical version by date (ReadDPPVersionByProductIdAndDate)

Returns the version that was current at the given instant (ISO 8601, UTC).

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sS "$BASE/dppsByProductIdAndDate/$PENC?date=$NOW" | jq '{ DPPStatus, LastUpdate }'
```

---

## 12. Register a DPP at the EU Registry (registerDPP)

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

## 13. Delete a DPP (DeleteDPPById)

Archives the final version (`DPPStatus: "Archived"`) and removes the active
passport. For a service-minted DID (Variant A) the DID is **revoked** first.

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
