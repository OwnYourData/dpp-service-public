# Example requests and responses — DPP of a lightbulb

End-to-end example for all endpoints of the DPP Service, based on an **LED lamp**
(E27, 8.5 W, 806 lm, 2700 K).

Base URL: `https://api.dpp.example.org/dpp/v1`

## Where do the field names come from?

| Level | Source |
|---|---|
| Outer frame of the DPP object (`digitalProductPassportId`, `uniqueProductIdentifier`, `granularity`, `dppSchemaVersion`, `dppStatus`, `lastUpdated`, `economicOperatorId`, `facilityId`) | **EN 18223:2026, Table 1** |
| Structure `DataElementCollection` / `SingleValuedDataElement` / `MultiValuedDataElement` / `RelatedResource` | **EN 18223:2026, 4.1.2 (Tables 2–5)** |
| Endpoints, HTTP mapping, status/result object | **EN 18222:2026 (Tables 13–19)** |
| Identifier formats (URI/URL, GS1 Digital Link, W3C DID) | **EN 18219:2026** |
| **The concrete product characteristics** (luminous flux, colour temperature, lifetime …) | **Not in 18223.** 18223 only defines the *framework*. Which data points a lightbulb has to carry is laid down in the ESPR act for the product group (lighting: Regulation (EU) 2019/2020 + 2019/2015) and in a data dictionary that every element points to via `DictionaryReference` (EN 18223:2026, 4.3). |

> The `DictionaryReference` values below are **illustrative** (ECLASS/IEC CDD style) and have to
> be replaced against the real repository of the product group.

## Identifiers in the example

| Role | Value |
|---|---|
| DPP ID | `https://dpp.lumina.example/01/09520123456788/8546` |
| Product ID (GS1 Digital Link) | `https://id.lumina.example/01/09520123456788` |
| Economic operator | `did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS` |

**Important:** DPP ID and product ID contain `/` and `:` — in the URL they are
**percent-encoded**:

```
https://dpp.lumina.example/01/09520123456788/8546
→ https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546
```

In what follows, `{DPP}` and `{PID}` are written for the encoded form, for readability.

## Authentication

Reading is open, writing requires a bearer token. Since 2026-08-17 the hosted instance
`https://dpp-service.ownyourdata.eu` runs with `DPP_AUTH_MODE=did`: a write request must
carry a self-issued JWT that is EdDSA-signed with the document key of the issuer's
`did:oyd` and that has the claims `iss` = `sub` = the issuer's DID,
`aud` = `https://dpp-service.ownyourdata.eu`, `iat`, `exp` (at most 900 s after `iat`)
and `jti`. An unsigned token (`alg: none`) is refused with `401`. In addition, only the
DID that created a passport may update or delete it; another DID gets `403` with
statusCode `ClientForbidden`. Reading stays open and needs no token.

How such a token is issued is described in
[docs/EXAMPLES.md](EXAMPLES.md), section *Issuing a token*.

The requests below write `Authorization: Bearer <token>`. Substitute a JWT of your
own with these claims, signed with the document key of your `did:oyd`:

```json
{
  "iss": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
  "sub": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
  "aud": "https://dpp-service.ownyourdata.eu",
  "iat": 1786000000,
  "exp": 1786000600,
  "jti": "3f1c…"
}
```

Header `{"alg":"EdDSA","typ":"JWT"}`. Against your own instance running
`permissive` the signature is not checked and any decodable token gets through;
against the hosted instance an unsigned one is refused with `401`.

---

## 1. CreateDPP — `POST /dpps`

Creates the passport. Writing → bearer token required.

### Request

```http
POST /dpp/v1/dpps HTTP/1.1
Content-Type: application/json
Authorization: Bearer <token>
```

```json
{
  "digitalProductPassportId": "https://dpp.lumina.example/01/09520123456788/8546",
  "uniqueProductIdentifier": "https://id.lumina.example/01/09520123456788",
  "granularity": "model",
  "dppSchemaVersion": "EN 18223:2026",
  "dppStatus": "Active",
  "economicOperatorId": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
  "facilityId": "https://id.lumina.example/414/0952012345001",
  "elements": [
    {
      "elementId": "ProductIdentification",
      "DictionaryReference": "https://dict.example.org/dpp/lighting/ProductIdentification",
      "elements": [
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "ModelIdentifier",
          "value": "LUM-A60-827-806",
          "valueDataType": "xsd:string"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "BrandName",
          "value": "Lumina",
          "valueDataType": "xsd:string"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "LightSourceType",
          "DictionaryReference": "0173-1#02-AAO677#003",
          "value": "LED",
          "valueDataType": "xsd:string"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "CapType",
          "value": "E27",
          "valueDataType": "xsd:string"
        }
      ]
    },
    {
      "elementId": "EnergyPerformance",
      "DictionaryReference": "https://dict.example.org/dpp/lighting/EnergyPerformance",
      "elements": [
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "OnModePower",
          "value": 8.5,
          "valueDataType": "xsd:decimal",
          "unitOfMeasure": "W"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "LuminousFlux",
          "value": 806,
          "valueDataType": "xsd:integer",
          "unitOfMeasure": "lm"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "LuminousEfficacy",
          "value": 94.8,
          "valueDataType": "xsd:decimal",
          "unitOfMeasure": "lm/W"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "EnergyEfficiencyClass",
          "value": "E",
          "valueDataType": "xsd:string"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "EprelRegistrationNumber",
          "value": "1234567",
          "valueDataType": "xsd:string"
        }
      ]
    },
    {
      "elementId": "LightQuality",
      "objectType": "DataElementCollection",
      "elements": [
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "CorrelatedColourTemperature",
          "value": 2700,
          "valueDataType": "xsd:integer",
          "unitOfMeasure": "K"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "ColourRenderingIndex",
          "value": 80,
          "valueDataType": "xsd:integer"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "Dimmable",
          "value": false,
          "valueDataType": "xsd:boolean"
        }
      ]
    },
    {
      "elementId": "Durability",
      "objectType": "DataElementCollection",
      "elements": [
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "RatedLifetime",
          "value": 15000,
          "valueDataType": "xsd:integer",
          "unitOfMeasure": "h"
        },
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "SwitchingCycles",
          "value": 100000,
          "valueDataType": "xsd:integer"
        }
      ]
    },
    {
      "elementId": "SubstancesOfConcern",
      "objectType": "DataElementCollection",
      "elements": [
        {
          "objectType": "SingleValuedDataElement",
          "elementId": "MercuryContent",
          "value": 0.0,
          "valueDataType": "xsd:decimal",
          "unitOfMeasure": "mg"
        },
        {
          "objectType": "MultiValuedDataElement",
          "elementId": "MaterialComposition",
          "ValueList": [
            {
              "elementId": "Polycarbonate",
              "value": 42.0,
              "valueDataType": "xsd:decimal"
            },
            {
              "elementId": "Aluminium",
              "value": 31.5,
              "valueDataType": "xsd:decimal"
            },
            {
              "elementId": "Electronics",
              "value": 26.5,
              "valueDataType": "xsd:decimal"
            }
          ]
        }
      ]
    }
  ],
  "dataElements": [
    {
      "objectType": "SingleValuedDataElement",
      "elementId": "DeclarationOfConformity",
      "value": "https://docs.lumina.example/doc/LUM-A60-827-806/doc.pdf",
      "valueDataType": "xsd:anyURI"
    }
  ]
}
```

### Response `201 Created`

The stored passport, enriched with `lastUpdated` (server timestamp):

```json
{
  "digitalProductPassportId": "https://dpp.lumina.example/01/09520123456788/8546",
  "uniqueProductIdentifier": "https://id.lumina.example/01/09520123456788",
  "granularity": "model",
  "dppSchemaVersion": "EN 18223:2026",
  "dppStatus": "Active",
  "lastUpdated": "2026-07-13T09:14:02Z",
  "economicOperatorId": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
  "facilityId": "https://id.lumina.example/414/0952012345001",
  "elements": [ "… as in the request …" ],
  "dataElements": [ "… as in the request …" ]
}
```

---

## 2. ReadDPPById — `GET /dpps/{DPP}`

Public read, no token needed.

### Request

```http
GET /dpp/v1/dpps/https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546 HTTP/1.1
Accept: application/json
```

### Response `200 OK`

Complete DPP document (identical to the response in 1.).

---

## 3. ReadDPPByProductId — `GET /dppsByProductId/{PID}`

Only the product code from the QR code is known, not the DPP ID.

### Request

```http
GET /dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456788 HTTP/1.1
```

### Response `200 OK`

The current (`Active`) passport for this product — complete DPP document.

---

## 4. ReadDPPVersionByIdAndDate — `GET /dppsByIdAndDate/{DPP}?date=…`

"What did the passport look like on 1 March 2026?"

### Request

```http
GET /dpp/v1/dppsByIdAndDate/did%3Aoyd%3AzQmY3j9By89J8rZR7SiewfA2ebNdoBWsx5BmJbD7in4aAsf?date=2026-03-01T00:00:00Z HTTP/1.1
```

### Response `200 OK`

The archived version that was valid at that point in time — for example still with
`"EnergyEfficiencyClass": "F"` before the reassessment.

### Error case `400 Bad Request` (Result object, EN 18222:2026 Table 13)

```json
{
  "statusCode": "ClientErrorBadRequest",
  "message": [
    {
      "messageType": "Error",
      "text": "Invalid 'date' (expected ISO 8601 UTC)",
      "correlationId": "b7c1f0e2-3a4d-4f9b-9c11-2f6d8a1e5c33",
      "timestamp": "2026-07-13T09:20:11Z"
    }
  ]
}
```

---

## 5. ReadDPPIdsByProductIds — `POST /dppsByProductIds`

Batch resolution: several product codes → the corresponding DPP IDs, with cursor pagination.

### Request

```http
POST /dpp/v1/dppsByProductIds?limit=100 HTTP/1.1
Content-Type: application/json
```

```json
[
  "https://id.lumina.example/01/09520123456788",
  "https://id.lumina.example/01/09520123456795"
]
```

### Response `200 OK`

```json
{
  "statusCode": "Success",
  "payload": [
    "https://dpp.lumina.example/01/09520123456788/8546",
    "https://dpp.lumina.example/01/09520123456795/8547"
  ],
  "nextCursor": null
}
```

If there are more hits than `limit`, `nextCursor` contains the last DPP ID delivered; the
next call appends `?cursor=<value>`.

---

## 6. UpdateDPP — `PATCH /dpps/{DPP}`

JSON Merge Patch per RFC 7396: only the fields sent are changed, `null` removes a field.
The previous version is archived automatically.

### Request

```http
PATCH /dpp/v1/dpps/https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546 HTTP/1.1
Content-Type: application/merge-patch+json
Authorization: Bearer <token>
```

```json
{
  "facilityId": "https://id.lumina.example/414/0952012345002"
}
```

### Response `200 OK`

The complete document after the patch — `facilityId` new, `lastUpdated` refreshed.

```json
{
  "digitalProductPassportId": "https://dpp.lumina.example/01/09520123456788/8546",
  "uniqueProductIdentifier": "https://id.lumina.example/01/09520123456788",
  "granularity": "model",
  "dppSchemaVersion": "EN 18223:2026",
  "dppStatus": "Active",
  "lastUpdated": "2026-07-13T10:02:47Z",
  "economicOperatorId": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
  "facilityId": "https://id.lumina.example/414/0952012345002",
  "elements": [ "… unchanged …" ]
}
```

---

## 7. ReadDataElementCollection — `GET /dpps/{DPP}/collections/{ElementId}`

Only one data group instead of the whole passport — for example for an energy label widget.

### Request

```http
GET /dpp/v1/dpps/{DPP}/collections/EnergyPerformance HTTP/1.1
```

### Response `200 OK`

```json
{
  "elementId": "EnergyPerformance",
  "DictionaryReference": "https://dict.example.org/dpp/lighting/EnergyPerformance",
  "elements": [
    { "objectType": "SingleValuedDataElement", "elementId": "OnModePower", "name": "On-mode power consumption", "value": 8.5, "valueDataType": "xsd:decimal", "unitOfMeasure": "W" },
    { "objectType": "SingleValuedDataElement", "elementId": "LuminousFlux", "name": "Luminous flux", "value": 806, "valueDataType": "xsd:integer", "unitOfMeasure": "lm" },
    { "objectType": "SingleValuedDataElement", "elementId": "LuminousEfficacy", "name": "Luminous efficacy", "value": 94.8, "valueDataType": "xsd:decimal", "unitOfMeasure": "lm/W" },
    { "objectType": "SingleValuedDataElement", "elementId": "EnergyEfficiencyClass", "name": "Energy efficiency class", "value": "E", "valueDataType": "xsd:string" },
    { "objectType": "SingleValuedDataElement", "elementId": "EprelRegistrationNumber", "name": "EPREL registration number", "value": "1234567", "valueDataType": "xsd:string" }
  ]
}
```

### Error case `404 Not Found`

```json
{
  "statusCode": "ClientErrorResourceNotFound",
  "message": [
    {
      "messageType": "Error",
      "text": "Collection not found",
      "correlationId": "0d5a9c31-7b2e-4a18-8f4c-9a2b6e7d1f04",
      "timestamp": "2026-07-13T10:05:33Z"
    }
  ]
}
```

---

## 8. UpdateDataElementCollection — `PATCH /dpps/{DPP}/collections/{ElementId}`

Merge patch on exactly one data group.

### Request

```http
PATCH /dpp/v1/dpps/{DPP}/collections/LightQuality HTTP/1.1
Content-Type: application/merge-patch+json
Authorization: Bearer <token>
```

```json
{
  "name": "Light quality (after remeasurement 2026)"
}
```

### Response `200 OK`

```json
{
  "elementId": "LightQuality",
  "objectType": "DataElementCollection",
  "elements": [ "… unchanged …" ]
}
```

---

## 9. ReadDataElement — `GET /dpps/{DPP}/elements/{Path}`

A single data point, addressed by its absolute ElementId path.
Path structure in this implementation:
`elements/<collectionId>/<elementId>`

### Request

```http
GET /dpp/v1/dpps/{DPP}/elements/EnergyPerformance/LuminousFlux HTTP/1.1
```

### Response `200 OK`

```json
{
  "objectType": "SingleValuedDataElement",
  "elementId": "LuminousFlux",
  "value": 806,
  "valueDataType": "xsd:integer",
  "unitOfMeasure": "lm"
}
```

---

## 10. UpdateDataElement — `PATCH /dpps/{DPP}/elements/{Path}`

Correct a single value — for example the reclassification of the efficiency class.

### Request

```http
PATCH /dpp/v1/dpps/{DPP}/elements/EnergyPerformance/EnergyEfficiencyClass HTTP/1.1
Content-Type: application/merge-patch+json
Authorization: Bearer <token>
```

```json
{
  "value": "D"
}
```

### Response `200 OK`

```json
{
  "objectType": "SingleValuedDataElement",
  "elementId": "EnergyEfficiencyClass",
  "value": "D",
  "valueDataType": "xsd:string"
}
```

---

## 11. RegisterProductDPP — `POST /registerDPP`

Registers the passport with the EU registry (EN 18222:2026, 5.2).

### Request

```http
POST /dpp/v1/registerDPP HTTP/1.1
Content-Type: application/json
Authorization: Bearer <token>
```

```json
{
  "dppRegistryEntry": {
    "uniqueProductIdentifier": "https://id.lumina.example/01/09520123456788",
    "uniqueEconomicOperatorIdentifier": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
    "backupEconomicOperatorIdentifier": "did:web:backup.dppservice.example"
  }
}
```

### Response `201 Created`

```json
{
  "statusCode": "SuccessCreated",
  "registrationId": "urn:ec:dpp:registry:9f1c8a2e-4d3b-4c7a-b1e5-6f0a2d9c4b71"
}
```

> The call to the real EC registry is still a placeholder in the service
> (`EcRegistryClient`, see `registry_controller.rb`).

---

## 12. DeleteDPPById — `DELETE /dpps/{DPP}`

Archives the current version and removes the active passport.

### Request

```http
DELETE /dpp/v1/dpps/https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546 HTTP/1.1
Authorization: Bearer <token>
```

### Response `204 No Content`

No body. Before deleting, the service writes a final snapshot with
`"dppStatus": "Archived"`. That snapshot is kept and remains retrievable via endpoint 4
(`dppsByIdAndDate`); `GET /dpps/{DPP}` returns `404` afterwards.

---

## Status codes at a glance (EN 18222:2026, Table 15)

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
