# Beispiel-Requests & -Responses — DPP eines Leuchtmittels

Durchgängiges Beispiel für alle Endpunkte des DPP Service anhand einer **LED-Lampe**
(E27, 8,5 W, 806 lm, 2700 K).

Basis-URL: `https://api.dpp.example.org/dpp/v1`

## Woher kommen die Feldnamen?

| Ebene | Quelle |
|---|---|
| Rahmen des DPP-Objekts (`DigitalProductPassportID`, `ProductID`, `Granularity`, `DPPSchemaVersion`, `DPPStatus`, `LastUpdate`, `EconomicOperatorID`, `FacilityID`) | **prEN 18223, Tabelle 1** |
| Struktur `DataElementCollection` / `SinglevaluedDataElement` / `MultivaluedDataElement` / `ValueElement` | **prEN 18223, 4.1.3 (Tabellen 2–5)** |
| Endpunkte, HTTP-Mapping, Status-/Result-Objekt | **prEN 18222 (Tabellen 13–19)** |
| Identifier-Formate (URI/URL, GS1 Digital Link, W3C DID) | **prEN 18219** |
| **Die konkreten Produktmerkmale** (Lichtstrom, Farbtemperatur, Lebensdauer …) | **NICHT in 18223.** 18223 legt nur das *Gerüst* fest. Welche Datenpunkte ein Leuchtmittel führen muss, steht im ESPR-Rechtsakt für die Produktgruppe (Beleuchtung: VO (EU) 2019/2020 + 2019/2015) und in einem Datenwörterbuch, auf das jedes Element per `DictionaryReference` zeigt (prEN 18223, 4.3). |

> Die `DictionaryReference`-Werte unten sind **illustrativ** (ECLASS-/IEC-CDD-Stil) und müssen
> gegen das reale Repository der Produktgruppe ersetzt werden.

## Identifier im Beispiel

| Rolle | Wert |
|---|---|
| DPP-ID | `https://dpp.lumina.example/01/09520123456788/8546` |
| Produkt-ID (GS1 Digital Link) | `https://id.lumina.example/01/09520123456788` |
| Wirtschaftsakteur | `did:web:lumina.example` |

**Wichtig:** DPP-ID und Produkt-ID enthalten `/` und `:` — in der URL **prozentkodiert**:

```
https://dpp.lumina.example/01/09520123456788/8546
→ https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546
```

Im Folgenden wird zur Lesbarkeit `{DPP}` bzw. `{PID}` für die kodierte Form geschrieben.

## Authentifizierung

Lesen ist offen, Schreiben braucht ein Bearer-Token. Der Service **dekodiert** den JWT
(Signaturprüfung gegen den OIDC-Provider ist noch TODO) — ein Platzhalter-String führt
daher zu `401`. Für lokale Tests:

```
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

(entspricht `{"sub":"did:web:lumina.example","scope":"dpp:write"}`, alg `none`)

---

## 1. CreateDPP — `POST /dpps`

Erzeugt den Pass. Schreibend → Bearer-Token erforderlich.

### Request

```http
POST /dpp/v1/dpps HTTP/1.1
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

```json
{
  "DigitalProductPassportID": "https://dpp.lumina.example/01/09520123456788/8546",
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "Granularity": "model",
  "DPPSchemaVersion": "prEN 18223:2025",
  "DPPStatus": "Active",
  "EconomicOperatorID": "did:web:lumina.example",
  "FacilityID": "https://id.lumina.example/414/0952012345001",
  "dataElementCollections": [
    {
      "ElementId": "ProductIdentification",
      "Name": "Produktidentifikation",
      "DictionaryReference": "https://dict.example.org/dpp/lighting/ProductIdentification",
      "DataElements": [
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "ModelIdentifier",
          "Name": "Modellkennung",
          "Value": "LUM-A60-827-806",
          "ValueDataType": "xs:string"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "BrandName",
          "Name": "Marke",
          "Value": "Lumina",
          "ValueDataType": "xs:string"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "LightSourceType",
          "Name": "Art der Lichtquelle",
          "DictionaryReference": "0173-1#02-AAO677#003",
          "Value": "LED",
          "ValueDataType": "xs:string"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "CapType",
          "Name": "Sockeltyp",
          "Value": "E27",
          "ValueDataType": "xs:string"
        }
      ]
    },
    {
      "ElementId": "EnergyPerformance",
      "Name": "Energieeffizienz",
      "DictionaryReference": "https://dict.example.org/dpp/lighting/EnergyPerformance",
      "DataElements": [
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "OnModePower",
          "Name": "Leistungsaufnahme im Ein-Zustand",
          "Value": 8.5,
          "ValueDataType": "xs:decimal",
          "UnitOfMeasure": "W"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "LuminousFlux",
          "Name": "Lichtstrom",
          "Value": 806,
          "ValueDataType": "xs:integer",
          "UnitOfMeasure": "lm"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "LuminousEfficacy",
          "Name": "Lichtausbeute",
          "Value": 94.8,
          "ValueDataType": "xs:decimal",
          "UnitOfMeasure": "lm/W"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "EnergyEfficiencyClass",
          "Name": "Energieeffizienzklasse",
          "Value": "E",
          "ValueDataType": "xs:string"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "EprelRegistrationNumber",
          "Name": "EPREL-Registrierungsnummer",
          "Value": "1234567",
          "ValueDataType": "xs:string"
        }
      ]
    },
    {
      "ElementId": "LightQuality",
      "Name": "Lichtqualität",
      "DataElements": [
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "CorrelatedColourTemperature",
          "Name": "Ähnlichste Farbtemperatur",
          "Value": 2700,
          "ValueDataType": "xs:integer",
          "UnitOfMeasure": "K"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "ColourRenderingIndex",
          "Name": "Farbwiedergabeindex (Ra)",
          "Value": 80,
          "ValueDataType": "xs:integer"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "Dimmable",
          "Name": "Dimmbar",
          "Value": false,
          "ValueDataType": "xs:boolean"
        }
      ]
    },
    {
      "ElementId": "Durability",
      "Name": "Haltbarkeit",
      "DataElements": [
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "RatedLifetime",
          "Name": "Bemessungslebensdauer (L70B50)",
          "Value": 15000,
          "ValueDataType": "xs:integer",
          "UnitOfMeasure": "h"
        },
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "SwitchingCycles",
          "Name": "Schaltzyklen bis Ausfall",
          "Value": 100000,
          "ValueDataType": "xs:integer"
        }
      ]
    },
    {
      "ElementId": "SubstancesOfConcern",
      "Name": "Besorgniserregende Stoffe",
      "DataElements": [
        {
          "@type": "SinglevaluedDataElement",
          "ElementId": "MercuryContent",
          "Name": "Quecksilbergehalt",
          "Value": 0.0,
          "ValueDataType": "xs:decimal",
          "UnitOfMeasure": "mg"
        },
        {
          "@type": "MultivaluedDataElement",
          "ElementId": "MaterialComposition",
          "Name": "Materialzusammensetzung",
          "ValueList": [
            {
              "ElementId": "Polycarbonate",
              "Name": "Polycarbonat",
              "Value": 42.0,
              "ValueDataType": "xs:decimal"
            },
            {
              "ElementId": "Aluminium",
              "Name": "Aluminium",
              "Value": 31.5,
              "ValueDataType": "xs:decimal"
            },
            {
              "ElementId": "Electronics",
              "Name": "Elektronik",
              "Value": 26.5,
              "ValueDataType": "xs:decimal"
            }
          ]
        }
      ]
    }
  ],
  "dataElements": [
    {
      "@type": "SinglevaluedDataElement",
      "ElementId": "DeclarationOfConformity",
      "Name": "EU-Konformitätserklärung",
      "Value": "https://docs.lumina.example/doc/LUM-A60-827-806/doc.pdf",
      "ValueDataType": "xs:anyURI"
    }
  ]
}
```

### Response `201 Created`

Der gespeicherte Pass, angereichert um `LastUpdate` (Server-Zeitstempel):

```json
{
  "DigitalProductPassportID": "https://dpp.lumina.example/01/09520123456788/8546",
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "Granularity": "model",
  "DPPSchemaVersion": "prEN 18223:2025",
  "DPPStatus": "Active",
  "LastUpdate": "2026-07-13T09:14:02Z",
  "EconomicOperatorID": "did:web:lumina.example",
  "FacilityID": "https://id.lumina.example/414/0952012345001",
  "dataElementCollections": [ "… wie im Request …" ],
  "dataElements": [ "… wie im Request …" ]
}
```

---

## 2. ReadDPPById — `GET /dpps/{DPP}`

Öffentliches Lesen, kein Token nötig.

### Request

```http
GET /dpp/v1/dpps/https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546 HTTP/1.1
Accept: application/json
```

### Response `200 OK`

Vollständiges DPP-Dokument (identisch zur Response aus 1.).

---

## 3. ReadDPPByProductId — `GET /dppsByProductId/{PID}`

Man kennt nur den Produktcode vom QR-Code, nicht die DPP-ID.

### Request

```http
GET /dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456788 HTTP/1.1
```

### Response `200 OK`

Der aktuelle (`Active`) Pass zu diesem Produkt — vollständiges DPP-Dokument.

---

## 4. ReadDPPVersionByProductIdAndDate — `GET /dppsByProductIdAndDate/{PID}?date=…`

„Wie sah der Pass am 1. März 2026 aus?"

### Request

```http
GET /dpp/v1/dppsByProductIdAndDate/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456788?date=2026-03-01T00:00:00Z HTTP/1.1
```

### Response `200 OK`

Die archivierte Version, die zu diesem Zeitpunkt gültig war — z. B. noch mit
`"EnergyEfficiencyClass": "F"` vor der Neubewertung.

### Fehlerfall `400 Bad Request` (Result-Objekt, prEN 18222 Tabelle 13)

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

Batch-Auflösung: mehrere Produktcodes → zugehörige DPP-IDs, mit Cursor-Paginierung.

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

Bei mehr Treffern als `limit` enthält `nextCursor` die letzte gelieferte DPP-ID; der
nächste Aufruf hängt `?cursor=<Wert>` an.

---

## 6. UpdateDPP — `PATCH /dpps/{DPP}`

JSON Merge Patch nach RFC 7396: nur die gesendeten Felder werden geändert,
`null` löscht ein Feld. Die alte Fassung wird automatisch archiviert.

### Request

```http
PATCH /dpp/v1/dpps/https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546 HTTP/1.1
Content-Type: application/merge-patch+json
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

```json
{
  "FacilityID": "https://id.lumina.example/414/0952012345002"
}
```

### Response `200 OK`

Das komplette Dokument nach dem Patch — `FacilityID` neu, `LastUpdate` aktualisiert.

```json
{
  "DigitalProductPassportID": "https://dpp.lumina.example/01/09520123456788/8546",
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "Granularity": "model",
  "DPPSchemaVersion": "prEN 18223:2025",
  "DPPStatus": "Active",
  "LastUpdate": "2026-07-13T10:02:47Z",
  "EconomicOperatorID": "did:web:lumina.example",
  "FacilityID": "https://id.lumina.example/414/0952012345002",
  "dataElementCollections": [ "… unverändert …" ]
}
```

---

## 7. ReadDataElementCollection — `GET /dpps/{DPP}/collections/{ElementId}`

Nur eine Datengruppe statt des ganzen Passes — z. B. für ein Energielabel-Widget.

### Request

```http
GET /dpp/v1/dpps/{DPP}/collections/EnergyPerformance HTTP/1.1
```

### Response `200 OK`

```json
{
  "ElementId": "EnergyPerformance",
  "Name": "Energieeffizienz",
  "DictionaryReference": "https://dict.example.org/dpp/lighting/EnergyPerformance",
  "DataElements": [
    { "@type": "SinglevaluedDataElement", "ElementId": "OnModePower", "Name": "Leistungsaufnahme im Ein-Zustand", "Value": 8.5, "ValueDataType": "xs:decimal", "UnitOfMeasure": "W" },
    { "@type": "SinglevaluedDataElement", "ElementId": "LuminousFlux", "Name": "Lichtstrom", "Value": 806, "ValueDataType": "xs:integer", "UnitOfMeasure": "lm" },
    { "@type": "SinglevaluedDataElement", "ElementId": "LuminousEfficacy", "Name": "Lichtausbeute", "Value": 94.8, "ValueDataType": "xs:decimal", "UnitOfMeasure": "lm/W" },
    { "@type": "SinglevaluedDataElement", "ElementId": "EnergyEfficiencyClass", "Name": "Energieeffizienzklasse", "Value": "E", "ValueDataType": "xs:string" },
    { "@type": "SinglevaluedDataElement", "ElementId": "EprelRegistrationNumber", "Name": "EPREL-Registrierungsnummer", "Value": "1234567", "ValueDataType": "xs:string" }
  ]
}
```

### Fehlerfall `404 Not Found`

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

Merge Patch auf genau eine Datengruppe.

### Request

```http
PATCH /dpp/v1/dpps/{DPP}/collections/LightQuality HTTP/1.1
Content-Type: application/merge-patch+json
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

```json
{
  "Name": "Lichtqualität (nach Nachmessung 2026)"
}
```

### Response `200 OK`

```json
{
  "ElementId": "LightQuality",
  "Name": "Lichtqualität (nach Nachmessung 2026)",
  "DataElements": [ "… unverändert …" ]
}
```

---

## 9. ReadDataElement — `GET /dpps/{DPP}/elements/{Pfad}`

Ein einzelner Datenpunkt, adressiert über seinen absoluten ElementId-Pfad.
Pfad-Aufbau in dieser Implementierung:
`dataElementCollections/<CollectionId>/DataElements/<ElementId>`

### Request

```http
GET /dpp/v1/dpps/{DPP}/elements/dataElementCollections/EnergyPerformance/DataElements/LuminousFlux HTTP/1.1
```

### Response `200 OK`

```json
{
  "@type": "SinglevaluedDataElement",
  "ElementId": "LuminousFlux",
  "Name": "Lichtstrom",
  "Value": 806,
  "ValueDataType": "xs:integer",
  "UnitOfMeasure": "lm"
}
```

---

## 10. UpdateDataElement — `PATCH /dpps/{DPP}/elements/{Pfad}`

Einzelnen Wert korrigieren — z. B. Neuklassifizierung der Effizienzklasse.

### Request

```http
PATCH /dpp/v1/dpps/{DPP}/elements/dataElementCollections/EnergyPerformance/DataElements/EnergyEfficiencyClass HTTP/1.1
Content-Type: application/merge-patch+json
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

```json
{
  "Value": "D"
}
```

### Response `200 OK`

```json
{
  "@type": "SinglevaluedDataElement",
  "ElementId": "EnergyEfficiencyClass",
  "Name": "Energieeffizienzklasse",
  "Value": "D",
  "ValueDataType": "xs:string"
}
```

---

## 11. PostNewDPPToRegistry — `POST /registerDPP`

Meldet den Pass beim EU-Register an (prEN 18222, 5.2).

### Request

```http
POST /dpp/v1/registerDPP HTTP/1.1
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

```json
{
  "ProductID": "https://id.lumina.example/01/09520123456788",
  "OperatorID": "did:web:lumina.example",
  "BackupID": "did:web:backup.dppservice.example"
}
```

### Response `201 Created`

```json
{
  "statusCode": "SuccessCreated",
  "registryIdentifier": "urn:ec:dpp:registry:9f1c8a2e-4d3b-4c7a-b1e5-6f0a2d9c4b71"
}
```

> Der Aufruf des echten EC-Registers ist im Service noch ein Platzhalter
> (`EcRegistryClient`, siehe `registry_controller.rb`).

---

## 12. DeleteDPPById — `DELETE /dpps/{DPP}`

Archiviert die aktuelle Version und entfernt den aktiven Pass.

### Request

```http
DELETE /dpp/v1/dpps/https%3A%2F%2Fdpp.lumina.example%2F01%2F09520123456788%2F8546 HTTP/1.1
Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJkaWQ6d2ViOmx1bWluYS5leGFtcGxlIiwic2NvcGUiOiJkcHA6d3JpdGUifQ.
```

### Response `204 No Content`

Kein Body. Vor dem Löschen schreibt der Service eine letzte Momentaufnahme mit
`"DPPStatus": "Archived"`. Diese bleibt erhalten und ist weiterhin über Endpunkt 4
(`dppsByProductIdAndDate`) abrufbar; `GET /dpps/{DPP}` liefert danach `404`.

---

## Statuscodes im Überblick (prEN 18222, Tabelle 16)

| Generischer Code | HTTP |
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
