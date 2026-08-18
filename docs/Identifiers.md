# Identifiers in the DPP ecosystem

At least nine different things in the DPP context are called an "identifier".
This document sorts them out, shows how they relate using one running example,
and names the traps.

References: EN 18219 (identifiers), EN 18220 (data carriers), EN 18222 (API),
EN 18223 (data model), DPP Registry User Guide.

---

## 1. The running example

A lamp made by the fictional manufacturer *Lumina*, with its passport held in a
hosting pod of the data intermediary.

| Role | Value |
|---|---|
| Economic operator's identity DID | `did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS` |
| the same, as `did:web` | `did:web:oydid.ownyourdata.eu:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS` |
| Product identifier | `https://id.lumina.example/01/09520123456791` |
| Facility identifier | `https://id.lumina.example/414/0952012345002` |
| Passport identifier | `did:oyd:zQmWVzyTPZ19ebpw2Dm9doEDP4qw9rVcs6M4v3iQMo7vpVS` |
| Short identifier | `cmodBSyBMVHP` |
| UPI (carrier + registry) | `https://dpp.go-data.at/p/cmodBSyBMVHP` |
| Long form (`serviceEndpoint`) | `https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456791` |
| Storage location | `base_url` = `https://dpp.go-data.at`, `collection_id` = `4` |
| Payload hash | `z4Fu…` (multibase, sha256) |
| Registration identifier | assigned by the registry, format unspecified |
| DPP service provider's DID | `did:oyd:zQmS…` (once delegation is in place) |

## 2. Overview

| # | Identifier | Identifies | Assigned by | Appears in | Standard |
|---|---|---|---|---|---|
| 1 | **Product ID** (`ProductID`) | the product (model, batch or item) | economic operator | passport document, `serviceEndpoint` | EN 18219 cl. 5 |
| 2 | **Facility ID** (`FacilityID`) | a production site | economic operator | passport document | EN 18219 cl. 6 |
| 3 | **Operator ID** (`EconomicOperatorID`) | the economic operator | economic operator | passport document | EN 18219 cl. 6 |
| 4 | **Passport ID** (`DigitalProductPassportID`) | the passport document | service provider (var. A) or holder (var. B) | passport document, VDR | EN 18223 |
| 5 | **Short ID** (`short_id`) | the passport, locally at the custodian | DPP service | internal only | — |
| 6 | **UPI** | the access path to the passport | derived from 5 | data carrier, registry | registry rule |
| 7 | **Registration identifier** | the registry record | EU registry | registry response | registry rule |
| 8 | **Storage location** (`base_url` + `collection_id`) | where the passport is kept | data intermediary | delegation, service index | — |
| 9 | **Payload hash** | one version of the passport content | computed | DID document, pod log | EN 18246 |

Alongside these sit the holder's **identity DID** and the service provider's
**service DID** — actor identities that appear only in tokens and delegations,
never inside the passport.

## 3. How they connect

```
   Data carrier (QR)
        │  contains
        ▼
   UPI  https://dpp.go-data.at/p/cmodBSyBMVHP        ← also filed with the registry
        │  resolves directly (200, no redirect)
        ▼
   Passport document  ──────────────────────────────────────────┐
        │  contains                                             │
        ├── ProductID   https://id.lumina.example/01/0952…      │
        ├── EconomicOperatorID  did:oyd:zQmPPw…                 │
        └── DigitalProductPassportID  did:oyd:zQmWVz…           │
                 │  resolve                                     │
                 ▼                                              │
        DID document (replayed from the signed log)             │
                 ├── service.serviceEndpoint ──▶ long form ─────┘
                 │        {base_url}/dpp/v1/dppsByProductId/{ProductID}
                 ├── service.payloadHash  z4Fu…  ──▶ compare with sha256(served bytes)
                 └── publicKeyMultibase   z6Mk…  ──▶ verify signature
```

Two ways into the same passport:

- **From the carrier:** `UPI` → passport. One scan, no prior knowledge, no
  resolver needed.
- **From the product identifier:** `ReadDPPByProductId` → passport. This is also
  the path the `serviceEndpoint` in the DID document takes.

## 4. Why the `serviceEndpoint` goes through the product identifier

The passport identifier is the hash of the DID document. The `serviceEndpoint`
sits inside that very document. An address containing the passport identifier
would therefore be part of the input to its own computation — circular. The
product identifier is known at minting time, is stable, and already serves as the
public read path.

## 5. Why the carrier bears a short link and not a DID

The registry caps the UPI at **50 characters**, requires `https`, and tolerates
only limited redirection:

| | Characters |
|---|---|
| `did:oyd:` + 47-character hash | 55 |
| EN 18219 Table B.12 example: `https://resolver.io/did:web:abc.com:model4TR/?service=item-dpp` | 62 |
| our UPI `https://dpp.go-data.at/p/cmodBSyBMVHP` | 37 |

A bare DID does not fit, and neither does the resolver URL the standard itself
shows. Hence the 35-character ceiling on `base_url`:
`len(base_url) + len("/p/") + 12 ≤ 50`.

**EN 18219 itself separates identifier from locator.** Table B.12 lists
`did:web:abc.com:model4TR` as the product identifier and the resolver URL as what
goes on the carrier. Our construction does the same thing with a shorter locator.

## 6. Mapping to the standard's ID schemes

EN 18219 clause 5 (products): 5.1 web-enabled structured path/query · 5.2
Identification Link (IEC 61406) · 5.3 DIDs · 5.4 product and group identification
· 5.5 DOI.
Clause 6 (economic operators and facilities): 6.1 structured path · 6.2 LEI ·
6.3 DIDs · 6.4 DOI.

In our deployment:

- **Product ID** → scheme 5.1 or 5.2 (HTTPS path in digital-link style).
- **Operator ID** → scheme 6.3 (DIDs for organizations).
- **Passport ID** → **no** scheme from EN 18219.

> **Important clarification.** The scope of EN 18219 is expressly limited to
> *"unique product identifiers, unique economic operator identifiers, and unique
> facility identifiers"*. The identifier of the **passport document** does not
> appear there at all — it is an attribute of the EN 18223 data model. Scheme 5.3
> ("DIDs for products") therefore describes a DID used as a **product**
> identifier, not as a passport identifier.
>
> It follows that the recommendation in 5.3.2 to use `did:web`, `did:ethr` or
> `did:ebsi` applies to the product identifier and does not reach our passport
> identifier at all. That every `did:oyd` is additionally addressable as
> `did:web` is therefore a voluntary bonus, not a conformance requirement.

## 7. The three confusions that keep recurring

**Product ID ≠ passport ID.** A product may have several passports over time
(reissue, refurbishment); a passport belongs to exactly one product. This is why
`ReadDPPByProductId` returns the *active* passport.

**UPI ≠ identifier in the strict sense.** The registry calls the field "Unique
Product Identifier" but requires a directly resolvable URL — it conflates
identifier and locator. In our design the UPI is a *derived access path*, not the
product identifier.

**UPI ≠ registration identifier.** The UPI goes *in*; the registration identifier
comes *out* and denotes the registry record. The user guide puts it this way: the
registration identifier "connects to an existing DPP Data via an UPI".

**Identity DID ≠ passport DID.** Delegations and write tokens are signed with the
holder's *identity* DID. In variant A the passport DID does not yet exist at
`CreateDPP` time.

## 8. Stability and mutability

| Identifier | Stable for | Changeable by |
|---|---|---|
| Product ID | the product's life | not at all (a change means a different product) |
| Passport ID | the passport's life | not at all — it is the hash of the initial document |
| DID document | — | a signed log entry by the key holder |
| `serviceEndpoint` | until the custodian changes | a log entry (but see below) |
| Payload hash | one version | every change produces a new one |
| UPI | the carrier's life | **not without reprinting** |

The last row is the known asymmetry: changing the **DPP service provider** costs
nothing, whereas changing the **custodian** breaks printed carriers, because the
UPI encodes the custodian's host.

## 9. Open points

1. Format of the registration identifier — the user guide gives none; our
   `registerDPP` returns a synthetic identifier for the time being.
2. The relationship between product identifier and UPI where the registry wants
   both: ours is derived and not equal to the product identifier. Whether the
   registry expects otherwise is not documented.
3. Carrier-level portability — a short, neutral redirecting host would decouple
   the UPI from the custodian. Per the user guide the registry rejects only
   "excessive redirects" but does not quantify the tolerance. Worth asking the
   helpdesk.
