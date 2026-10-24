# DPP Service — Digital Product Passport API

Rails 7 **API-only** service implementing the Digital Product Passport endpoints
defined by the CEN/CENELEC JTC 24 standards. The REST contract is derived
from **EN 18222:2026** (APIs for product passport lifecycle management), with
payloads from **EN 18223:2026** (system interoperability / semantic model).

> ℹ️ **Public snapshot.** This repository is a snapshot of an internal
> development repository, published without history and refreshed
> periodically. Pull requests here cannot be merged — please open an issue
> instead, or contact [OwnYourData](https://www.ownyourdata.eu).

> ⚠️ All eight JTC 24 standards are published as EN …:2026. Six of them are
> cited in the Official Journal as harmonised standards; EN 18239 and EN 18246
> are published but not yet cited. The payload, the method set and the
> identifier schemes here follow the published editions. The element path of
> the fine-granular methods is an RFC 9535 JSONPath singular query
> (EN 18222:2026 8.1); the element identifiers separated by `/` are accepted as
> well. The two collection operations are an addition beyond the published
> method set. The `semanticId` base URI `https://jtc24/...` is still a
> placeholder.

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
`did:oyd`, and only the DID that created a passport may change it. Each token is
accepted once, so a client mints one per request. Reading is public and needs
no token. A stand-alone instance starts in `permissive` mode,
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

Two demonstrations of the same lifecycle, one from each side. Start with
whichever matches how you would use it.

| Demo | What it shows |
|---|---|
| [docs/DPP-Service-Demo.md](docs/DPP-Service-Demo.md) | **the API, on the command line** — a passport created, corrected, handed to a custodian and ended, as `curl` calls to paste |
| [docs/DPP-Manager-Demo.md](docs/DPP-Manager-Demo.md) | **the application, with screenshots** — the same lifecycle as an economic operator sees it, in the DPP Manager on their own computer |

The rest:

| File | What it covers |
|---|---|
| [docs/Standalone.md](docs/Standalone.md) | running the service on your own, without the intermediary's pod |
| [docs/EXAMPLES.md](docs/EXAMPLES.md) | the walkthrough: issuing a token, then every endpoint as copy-paste `curl` calls |
| [docs/examples-lightbulb.md](docs/examples-lightbulb.md) | one complete worked example (an LED lamp) with full request and response payloads |
| [docs/Identifiers.md](docs/Identifiers.md) | the six things called "identifier" in the DPP context, how they relate, and which of them ends up on the data carrier |
| [docs/Integrity.md](docs/Integrity.md) | how the identifier, the version chain and the payload commitment fit together, and what a reader can verify without trusting anyone |
| [docs/AccessClasses.md](docs/AccessClasses.md) | the vocabulary of access classes (public, legitimate interest, authority), the access policy that assigns one class to every attribute of a passport, how a policy is registered and attached to a passport, access grants and revoking them, what each reader gets on the read paths, and the access log |
| [bin/verify_dpp](bin/verify_dpp) | scan a carrier link, resolve the passport, recompute the hash: `bundle exec ruby bin/verify_dpp <carrier URL>` |
| [bin/attest_payload](bin/attest_payload) | the holder side of the same coin: hash what the custodian delivers and sign the entry with your own document key: `bundle exec ruby bin/attest_payload <carrier URL> --keys <file>` |
| [bin/sign_dpp](bin/sign_dpp) | sign a passport as its economic operator, with the key of your own DID, and hand the signature to the service: `bundle exec ruby bin/sign_dpp <dppId> --keys <file>` |
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
| sign a passport as its economic operator | PUT | `/dpp/v1/dpps/:dpp_id/signature` |
| read the mandate held for a passport | GET | `/dpp/v1/dpps/:dpp_id/delegation` |
| hand over a fresh mandate | POST | `/dpp/v1/dpps/:dpp_id/delegation` |
| service discovery (service DID, audience, reader DIDs, authority issuers) | GET | `/.well-known/dpp-service` |
| read a collection directly | GET | `/dpp/v1/dpps/:dpp_id/collections/:element_id` |
| update a collection directly | PATCH | `/dpp/v1/dpps/:dpp_id/collections/:element_id` |
| register the access policy of a product type | PUT | `/dpp/v1/access-policies` |
| list the gaps of a passport's access policy | GET | `/dpp/v1/dpps/:dpp_id/access-policy` |
| register an access grant | PUT | `/dpp/v1/access-grants` |
| list the access grants one has issued | GET | `/dpp/v1/access-grants` |
| revoke an access grant one has issued | DELETE | `/dpp/v1/access-grants/:jti` |
| read the entries of the access log that concern one | GET | `/dpp/v1/access-log` |
| health check | GET | `/up` |
| image tag and commit of the running instance | GET | `/version` |

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

`delegation` concerns the mandate under which the service reaches the
custodian: it has a lifetime, the passport does not. GET says which mandate is
held, POST replaces it with a fresh one; neither moves the passport. The rules
are in [docs/Delegation.md](docs/Delegation.md). `/.well-known/dpp-service`
names the DID an economic operator delegates to, and for each pod the reader
DID under which the intermediary registers the service as protected statutory
reader.

Identifiers used as a single path segment (`:dpp_id`, `:product_id`) must be
URL-encoded by the client. `*element_path` holds the elementIdPath of
EN 18222:2026 8.1, an RFC 9535 JSONPath singular query over the element
identifiers such as `$.EnergyPerformance.LuminousFlux`, percent-encoded; a query
that is not RFC 9535 syntax or can select more than one element is answered
with `400`. The element identifiers separated by `/` address the same element.
An element path beyond the access classes the reader holds for the passport
is answered with `401` without a bearer token and with `403` with a valid one,
whether the element exists or not
([docs/AccessClasses.md](docs/AccessClasses.md) §8). Every `401` names the
`Bearer` scheme in `WWW-Authenticate`.

## How the standards map to the code

| Standard | Topic | Where in the app |
|---|---|---|
| EN 18222:2026 | API methods, status codes, Result object | routes, `app/controllers`, `ApiStatus` |
| EN 18223:2026 | DPP semantic model (payload) | `app/models/dpp.rb`, `docs/openapi.yaml` |
| EN 18216:2026 | Transport and formats (TLS, JSON) | `force_ssl`; TLS 1.2 and 1.3 at the ingress; response content types |
| EN 18239:2026 | Access rights and security | `TokenAuthenticatable`; tokens accepted once in `TokenUse`; rate limit in `ApplicationController`, counted across replicas in `RateCounter`; cross-origin policy in `config/initializers/cors.rb`; access classes and policies in `AccessClass`, `AccessPolicy`, `config/vocab/`; access grants in `AccessGrant`; reading per role in `PassportAccess`; access log in `AccessLog` |
| EN 18221:2026 | Storage, archiving, versioning | `DppVersion`, `Dpp#archive_current_version!` |
| EN 18219:2026 | Unique identifiers, W3C DID | `DidOyd`, [`did:oyd`](https://ownyourdata.github.io/oydid/) and `did:web` |
| EN 18246:2026 | Authenticity and integrity | DID document as anchor, `PayloadCommitment`, `PayloadIntegrity`, the signature of the economic operator in `OperatorSignature`, `bin/verify_dpp`, `bin/sign_dpp` |
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

1. **Access log kept inside the database (EN 18239:2026).** Signature
   verification, owner binding, access classes, per-attribute access policies,
   access grants, revoking them and reading per role are implemented, and every
   access to the controlled part is logged
   ([docs/AccessClasses.md](docs/AccessClasses.md)). Entries are only ever
   added and PostgreSQL refuses to change them, but the log is not anchored
   outside the database: someone who can change the database directly can
   change it unnoticed. Grants for `authority` are taken only from the issuers
   listed in `DPP_AUTHORITY_ISSUERS`.
2. **EU registry client (EN 18222:2026 §5).** `registerDPP` checks the entry and
   answers `502` (`registryNotConnected`); nothing is registered. The Commission
   publishes no API specification for the EU DPP Registry.
3. **Content negotiation (EN 18216:2026 §5).** JSON is implemented; XML, JSON-LD
   and HTML renderers are not.
4. **Data dictionary (EN 18223:2026 §4.3).** The element-path resolver walks the
   document structurally instead of validating against a product-group
   dictionary.
5. **Data integrity (EN 18246:2026).** The content is bound to the identifier:
   every change appends a signed log entry carrying `payloadHash`, the hash of
   the payload as the custodian delivers it, and `bin/verify_dpp` checks that
   from the public web alone. Where the holder keeps the document key, the
   service can only report the expected hash and leave the passport `pending` —
   it cannot sign in their place. The holder does that themselves, with
   `bin/attest_payload` or the DPP Manager, and the service picks the change up
   when the passport is next read. The economic operator signs the public part
   of a passport the service keeps itself with the key of its own DID
   ([docs/Integrity.md](docs/Integrity.md) section 10); a passport held by a
   custodian carries no such signature. What remains open is the trust anchor:
   it is self-managed, EN 18246:2026 expects an accredited one, so electronic
   attestation of attributes (EAA) is not covered.

## Citing this

`CITATION.cff` in the repository root carries the metadata; each release is
archived on Zenodo under a concept DOI that always resolves to the latest
version.

## Funding

<!-- funding:begin -->
The DPP Service is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating a Digital Product Passport based Data-Service Ecosystem. This Lighthouse Project has been made possible by financial contributions from the Austrian Federal Ministry of Innovation, Mobility and Infrastructure ([BMIMI](https://www.bmimi.gv.at/en.html), formerly BMK), supported by the Austrian Research Promotion Agency (FFG) under grant number [917177](https://projekte.ffg.at/projekt/5128301), as well as from the German Federal Ministry of Research, Technology and Space (BMFTR, formerly BMWK), supported by the German Research Promotion Agency (DLR-PT).
<!-- funding:end -->

## License

[Apache 2.0 License 2026 - OwnYourData.eu](https://github.com/OwnYourData/dpp-service-public/blob/main/LICENSE)
