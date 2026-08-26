# DPP Service — Digital Product Passport API

Rails 7 **API-only** service implementing the Digital Product Passport endpoints
defined by the CEN/CENELEC JTC 24 draft standards. The REST contract is derived
from **EN 18222:2026** (APIs for product passport lifecycle management), with
payloads from **EN 18223:2026** (system interoperability / semantic model).

> ℹ️ **Public snapshot.** This repository is a snapshot of an internal
> development repository, published without history and refreshed
> periodically. Pull requests here cannot be merged — please open an issue
> instead, or contact [OwnYourData](https://www.ownyourdata.eu).

> ⚠️ Six of the eight JTC 24 standards were published as EN …:2026 and are
> cited in the Official Journal; EN 18239 and EN 18246 are still drafts and are
> cited as `prEN`. The payload, the method set and the identifier schemes here
> follow the published editions. Two deviations are deliberate and named where
> they occur: the element path is a path of element identifiers rather than
> RFC 9535 JSONPath (EN 18222:2026 8.1), and the two collection operations are
> an addition beyond the published method set. The `semanticId` base URI
> `https://jtc24/...` is still a placeholder.

## Running it

**[docs/Standalone.md](docs/Standalone.md) is the guide** — how to set the
service up so it stores Digital Product Passports in its own database and runs
without any external infrastructure beyond a PostgreSQL server.

```bash
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Swagger UI at `http://localhost:3000/api-docs`, rendered from the OpenAPI 3.0
description in [`docs/openapi.yaml`](docs/openapi.yaml).

## Hosted instance

OwnYourData operates a public instance at
**https://dpp-service.ownyourdata.eu**. That deployment does not keep passport
documents in its own database: it stores them in a hosting pod operated by the
data intermediary **[DID FlexCo](https://intermediary.at)**, which then also
serves them publicly. The service keeps only an index and the storage
configuration.

That mode is out of scope for this snapshot — it needs a pod provisioned by the
intermediary and credentials issued by them. Everything documented here is the
stand-alone path, which is fully functional on its own.

The hosted instance runs with `DPP_AUTH_MODE=did`: writing requires a bearer
token that is a self-issued JWT, signed with the document key of the issuer's
`did:oyd`, and only the DID that created a passport may change it. Reading is
public and needs no token. A stand-alone instance starts in `permissive` mode,
where the signature is not checked — see [docs/Standalone.md](docs/Standalone.md).

`did:oyd` is one of the DID methods EN 18219:2026 admits, specified in
**[the OYD DID Method](https://ownyourdata.github.io/oydid/)** and implemented
by the [`oydid` gem and CLI](https://rubygems.org/gems/oydid)
([source](https://github.com/ownyourdata/oydid)). The identifier is the hash of
its own DID document, so it is self-certifying: what the specification calls
`calculate_hash` and `retrieve_log` is what `oydid read --show-verification`
recomputes step by step. The service uses it for the passport identifier and for
actor identities; nothing in the API is specific to it, and `docs/Identifiers.md`
says which identifier is which.

## Documentation

| File | What it covers |
|---|---|
| [docs/Standalone.md](docs/Standalone.md) | running the service on your own, without the intermediary's pod |
| [docs/EXAMPLES.md](docs/EXAMPLES.md) | the walkthrough: issuing a token, then every endpoint as copy-paste `curl` calls |
| [docs/examples-lightbulb.md](docs/examples-lightbulb.md) | one complete worked example (an LED lamp) with full request and response payloads |
| [docs/Identifiers.md](docs/Identifiers.md) | the six things called "identifier" in the DPP context, how they relate, and which of them ends up on the data carrier |
| [docs/verification/](docs/verification/) | the record of the run that moved a live passport between two custodians without touching the printed carrier |
| [docs/openapi.yaml](docs/openapi.yaml) | the machine-readable contract: an OpenAPI 3.0 description of every endpoint, which the service also serves through a Swagger UI at `/api-docs` |

## Endpoints (EN 18222:2026, Tables 16–18)

| Method (standard) | HTTP | Path |
|---|---|---|
| ReadDPPById | GET | `/dpp/v1/dpps/:dpp_id` |
| CreateDPP | POST | `/dpp/v1/dpps` |
| UpdateDPPById (RFC 7396) | PATCH | `/dpp/v1/dpps/:dpp_id` |
| DeleteDPPById | DELETE | `/dpp/v1/dpps/:dpp_id` |
| ReadDPPByProductId | GET | `/dpp/v1/dppsByProductId/:product_id` |
| ReadDPPVersionByIdAndDate | GET | `/dpp/v1/dppsByIdAndDate/:dpp_id?date=` |
| ReadDPPIdsByProductIds | POST | `/dpp/v1/dppsByProductIds` |
| RegisterProductDPP | POST | `/dpp/v1/registerDPP` |
| ReadDataElement | GET | `/dpp/v1/dpps/:dpp_id/elements/*element_path` |
| UpdateDataElement | PATCH | `/dpp/v1/dpps/:dpp_id/elements/*element_path` |

Beyond the standard's methods:

| | HTTP | Path |
|---|---|---|
| change of custodian | POST | `/dpp/v1/dpps/:dpp_id/custody` |
| read a collection directly | GET | `/dpp/v1/dpps/:dpp_id/collections/:element_id` |
| update a collection directly | PATCH | `/dpp/v1/dpps/:dpp_id/collections/:element_id` |

A collection is a subclass of DataElement (EN 18223:2026 4.1.2.4) and is
reachable through the element path, so EN 18222:2026 Table 18 defines
ReadDataElement and UpdateDataElement only. The two collection operations exist
because addressing a top-level collection by name is convenient, not because
the standard asks for them.

`custody` moves a pod-backed passport to the custodian named by a new
`X-DPP-Storage` mandate. The identifiers do not change, which is the point: the
product identifier is what was printed. The previous custodian keeps serving
unless `release_previous=true` is passed, because retiring it is bounded by the
DNS time-to-live in the operator's zone. `docs/verification/` records a run of
this against two live deployments.

Identifiers used as a single path segment (`:dpp_id`, `:product_id`) must be
URL-encoded by the client. `*element_path` is a glob holding an absolute
element path: the elementId of each level, separated by `/`.

## How the standards map to the code

| Standard | Topic | Where in the app |
|---|---|---|
| EN 18222:2026 | API methods, status codes, Result object | routes, `app/controllers`, `ApiStatus` |
| EN 18223:2026 | DPP semantic model (payload) | `app/models/dpp.rb`, `docs/openapi.yaml` |
| EN 18216:2026 | Transport and formats (TLS, JSON) | `force_ssl`, response content types |
| prEN 18239 | Access rights and security | `TokenAuthenticatable` |
| EN 18221:2026 | Storage, archiving, versioning | `DppVersion`, `Dpp#archive_current_version!` |
| EN 18219:2026 | Unique identifiers, W3C DID | `DidOyd`, [`did:oyd`](https://ownyourdata.github.io/oydid/) and `did:web` |
| prEN 18246 | Authenticity and integrity | DID document as anchor |
| DIN DKE SPEC 99100 | Battery passport attributes | `db/seeds.rb` example content |

Errors return a **Result** object (`statusCode` plus `message[]`) per EN 18222:2026
Tables 12–15, mapped in `app/controllers/concerns/api_status.rb`.

## Tests

```bash
mkdir -p storage
RAILS_ENV=test bin/rails db:prepare
bundle exec rspec
```

## Open items before production use

1. **Role model (prEN 18239).** Signature verification and owner binding are
   implemented — set `DPP_AUTH_MODE=did` and bearer tokens must be self-issued
   JWTs signed with the document key of the issuer's `did:oyd`. Still missing:
   the roles (authority, refurbisher, consumer) and the distinction between
   public data, controlled data and trade secrets.
2. **EC Registry client (EN 18222:2026 §5).** `registerDPP` returns a synthetic
   identifier; the real endpoint is defined by EU implementing acts.
3. **Content negotiation (EN 18216:2026 §5).** JSON is implemented; XML, JSON-LD
   and HTML renderers are not.
4. **Data dictionary (EN 18223:2026 §4.3).** The element-path resolver walks the
   document structurally instead of validating against a product-group
   dictionary.
5. **Data integrity (prEN 18246).** Signing and electronic attestation of
   attributes (EAA) are not implemented.

## Citing this

`CITATION.cff` in the repository root carries the metadata; each release is
archived on Zenodo under a concept DOI that always resolves to the latest
version.

## License

[Apache 2.0 License 2026 - OwnYourData.eu](https://github.com/OwnYourData/dpp-service-public/blob/main/LICENSE)
