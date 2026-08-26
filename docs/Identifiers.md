# Identifiers in the DPP ecosystem

At least six different things in the DPP context are called an "identifier".
This document sorts them out, shows how they relate using one running example,
and names the traps.

References: EN 18219 (identifiers), EN 18220 (data carriers), EN 18221
(persistence), EN 18222 (API), EN 18223 (data model), EN 18246 (integrity),
DPP Registry User Guide.

---

## 1. The running example

A lamp made by the fictional manufacturer *Lumina*, with its passport held in a
hosting pod of the data intermediary.

| Role | Value |
|---|---|
| Economic operator's identity DID | `did:oyd:zQmX493GLVxE8Wasc8ANTdZmq4YUsvdk5j6Daf7iQaPECt6` |
| Product identifier = carrier string | `https://p.lumina.at/01/09520123456791/21/000123` (47 characters) |
| Facility identifier | `https://p.lumina.at/414/0952012345002` |
| Passport identifier | `did:oyd:zQmSE1hzumtZ7AoK1qhHf4t5kiKsujMsJSHqoXtWrdd7K7W` |
| Long form (`serviceEndpoint`) | `https://dpp.data-vault.eu/dpp/v1/dppsByProductId/https%3A%2F%2Fp.lumina.at%2F01%2F09520123456791%2F21%2F000123` |
| Backup identifier | identifier of the backup service provider — still open |
| Registration identifier | assigned by the registry, format unspecified |
| DPP service provider's DID | `did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd` |

`p.lumina.at` belongs to the **economic operator** and is pointed at the
custodian by a DNS record. That is what makes a change of custodian a change in
the operator's own zone rather than a reprint.

## 2. Overview

| # | Identifier | Identifies | Assigned by | Appears in | Standard |
|---|---|---|---|---|---|
| 1 | **Unique product identifier** (`uniqueProductIdentifier`) | the product **and** the access path | economic operator | data carrier, registry, passport document | EN 18219 cl. 5, 3.1.25, 4.5.2 (1) |
| 2 | **Facility ID** (`facilityId`) | a production site | economic operator | passport document | EN 18219 cl. 6 |
| 3 | **Operator ID** (`economicOperatorId`) | the economic operator | economic operator | passport document, `registerDPP` | EN 18219 cl. 6 |
| 4 | **Passport ID** (`digitalProductPassportId`) | the passport document | service provider (var. A) or holder (var. B) | passport document, VDR | EN 18223 |
| 5 | **Backup ID** | the backup service provider | operator / contract | `registerDPP` | EN 18221 cl. 4.5, EN 18222 Tab. 11 |
| 6 | **Registration identifier** (`registrationId`) | the registry record | EU registry | registry response | EN 18222 cl. 5.2 |

Alongside these sit the holder's **identity DID** and the service provider's
**service DID** — actor identities that appear only in tokens and delegations,
never inside the passport.

There is **no separate carrier token**. EN 18219 cl. 3.1.25 defines the unique
product identifier as *one* string that identifies the product and also enables
the web link to the passport, and cl. 4.5.2 (1) requires that very string to be
retrievable from the carrier.

## 3. How they connect

```
   Data carrier (QR, NFC)
        │   encodes exactly ONE string
        ▼
   uniqueProductIdentifier   https://p.lumina.at/01/09520123456791/21/000123
        │                      └─ host: economic operator
        │                                   └─ path: scheme A or B
        │   DNS record, no redirect
        ▼
   Custodian           dpp.data-vault.eu
        ▼
   Passport document   uniqueProductIdentifier · digitalProductPassportId ─▶ ①
        │              economicOperatorId ──▶ ②  ·  facilityId
        │              granularity · dppSchemaVersion · dppStatus · lastUpdated
        │   DID resolution
        ▼
   DID documents       ① passport: serviceEndpoint, publicKeyMultibase
                       ② operator: publicKeyMultibase
```

Two ways into the same passport. **From the carrier:** one scan, no prior
knowledge, no resolver, one request — covered by EN 18219 cl. 4.4.1. Resolution
happens in DNS; nothing is redirected, so the registry's redirect tolerance is
never relied upon. **From the product identifier:** `ReadDPPByProductId`, which
is also the path the `serviceEndpoint` takes. The path segment
`dppsByProductId/{productId}` is taken verbatim from EN 18222 cl. 8.2 Tab. 17.

Neither replaces the three mandatory methods of EN 18222 cl. 4.1 — the carrier
path is an additional entry point, not an API.

## 4. Why the `serviceEndpoint` goes through the product identifier

The passport identifier is the hash over the DID document. The `serviceEndpoint`
sits inside that document. An address containing the passport identifier would
therefore be part of the input to its own computation — circular. The product
identifier is known at minting time, stable, and is the public read path anyway.

The same circularity applies to a self-certifying **product** identifier: the
document behind it cannot contain the carrier URL either.

## 5. What the carrier bears

The carrier bears the product identifier itself. Two schemes are admissible
here, and they trade differently.

**A — GS1 Digital Link** (EN 18219 cl. 5.2)

```
https://p.lumina.at/01/09520123456791/21/000123     47 characters
```

Descriptive: a scanner reads GTIN and serial number from the path without a
network call, and the service checks the declared `granularity` against the path
instead of trusting it. Price: the prefix is licensed annually from an issuing
agency registered under ISO/IEC 15459-2.

**B — identification link with a self-certifying path** (EN 18219 cl. 5.3,
EN IEC 61406-1)

```
https://p.lumina.at/zAkk4XNgY3rjJLXvWgRraEM4Nmfm    48 characters
```

The path is the multibase multihash of a product `did:oyd`, without the
`did:oyd:` prefix. Dropping the prefix is lossless, so the same string has two
readings: call it as a web address, or prepend `did:oyd:` and resolve it as a
DID. No issuing agency, and the string commits to a document rather than merely
addressing one. Price: the path describes nothing, and `granularity` has to be
believed.

**The character budget.** The registry limits the identifier to 50 characters
over HTTPS. Usable path = 41 − length of host. A 144-bit BLAKE2b digest yields
28 characters, so scheme B needs a host of at most 13 characters. The digest
size is a one-way decision: it is fixed with the first carrier printed, and
increasing it later would require a shorter host — which changes every carrier
already in the field.

**Not admissible on the carrier: a bare DID.** It is not an https URL. On the
software question the published edition is quieter than the draft was: Annex B
Table B.10 notes for the DID scheme, under cl. 4.6.2 (2) consumer usage, that
the identifier has to be parsed and resolved, where every other scheme reads
"no additional software needed" — but that annex is informative. The multihash
form above sidesteps the argument: it resolves in any browser.

## 6. Mapping to the standard's ID schemes

EN 18219 cl. 5 lists five schemes for products, and **none of them is unusable
by the standard's own terms** — cl. 4.3.2 (2) only requires URL form or a
defined conversion into one. Two remain here because of constraints from
outside the standard:

| Scheme | What it is | Here |
|---|---|---|
| 5.2 web enabled, structured path and query | GS1 application identifiers | **A**, by the path; we admit no query strings |
| 5.3 identification link | EN IEC 61406-1, self-issuing | **B** |
| 5.4 DID | W3C DID | out — carrier-capable only behind a web resolver |
| 5.5 products and product groups | binary encoding in an RFID tag | out — different carrier type |
| 5.6 DOI | ISO 26324 | out — foreign resolver, too long |

The three external constraints: the **registry** requires https and at most 50
characters; **cl. 4.6.2 (2)** forbids requiring software downloads on the
consumer path; and our own **anti-lock-in criterion** admits no third party's
resolver in the access path. The standard permits the latter explicitly
(cl. 4.4.3 (2)) — we simply do not want it.

The path and the query string are one scheme in the published edition, and
the query half is excluded by our own decision: `…/01/0952…` and
`…/01/0952…?17=271231` would otherwise yield the same lookup key.

## 7. The three confusions that keep recurring

**Product ID versus passport ID.** The product identifier names the product and
survives re-minting. The passport identifier names one document; mint the
passport again and it changes. That is why the carrier bears the product
identifier, never the passport identifier.

**Carrier host versus custodian host.** The carrier bears a host belonging to
the *economic operator*. The custodian's host appears only in the
`serviceEndpoint` — deliberately, because that is the signed statement about who
holds the passport. The carrier moves by DNS; custody moves only by a signed log
entry.

**Identifier versus integrity proof.** A payload hash names nothing; it binds a
version of the content. It is computed, not assigned, and is therefore not an
identifier — even though the passport identifier happens to be a hash too.

## 8. Stability and mutability

| Value | Changes when | Consequence |
|---|---|---|
| Product ID | never, once printed | the carrier depends on it |
| Passport ID | on re-minting | never put it on a carrier |
| `serviceEndpoint` | on a change of custodian | a signed log entry, no reprint |
| carrier host in DNS | on a change of custodian | a record in the operator's own zone |
| storage location | on a change of custodian | internal, not in the document |

A `did:oyd` is the hash over its own DID document, so **every update produces a
new identifier** while the earlier ones stay resolvable through the log chain.
The resolver returns the requested DID in `id`; `canonicalId` names the version
the log resolves to, and `equivalentId` lists the others. The identifier that
was issued therefore keeps resolving as its document evolves.

## 9. Open points

* The **backup service provider** of EN 18221 cl. 4.5 is not yet
  appointed. The standard makes the backup copy mandatory and the primary
  provider optional — the reverse of what one might assume.
* The **payload hash** in the DID log and the detached payload signature are
  planned, not deployed. Until both exist, the public key in the DID document
  secures the log chain but not the payload.
* **Retiring a previous custodian** waits for the DNS time-to-live of the
  operator's record. That value is often set by the operator's DNS provider and
  not configurable; removing the host earlier breaks access for every client
  whose resolver still holds the old record.
* A **certificate** for the operator's name has to reach the new custodian
  before the name points there. An ACME HTTP-01 challenge goes wherever the name
  resolves, which is still the old custodian at that moment.
