# DPP Service — Digital Product Passport API

Rails 7 **API-only** service implementing the Digital Product Passport endpoints
defined by the CEN/CENELEC JTC 24 draft standards. The REST contract is derived
from **prEN 18222** (APIs for product passport lifecycle management), with
payloads from **prEN 18223** (system interoperability / semantic model).

> ℹ️ **Public snapshot.** This repository is a snapshot of an internal
> development repository, published without history and refreshed
> periodically. Pull requests here cannot be merged — please open an issue
> instead, or contact [OwnYourData](https://www.ownyourdata.eu).

> ⚠️ The source standards are 2025 drafts (*Entwurf* / CEN Enquiry) and are
> technology-neutral. This implementation must be re-validated against the
> final published standards. The `semanticId` base URI `https://jtc24/...` is a
> placeholder taken from the drafts.

## Running it

**[docs/Standalone.md](docs/Standalone.md) is the guide** — how to set the
service up so it stores Digital Product Passports in its own database and runs
without any external infrastructure beyond a PostgreSQL server.

```bash
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Swagger UI at `http://localhost:3000/api-docs`, the machine-readable contract in
[`docs/openapi.yaml`](docs/openapi.yaml).

## Hosted instance

OwnYourData operates a public instance at
**https://dpp-service.ownyourdata.eu**. That deployment does not keep passport
documents in its own database: it stores them in a hosting pod operated by the
data intermediary **DID FlexCo**, which then also serves them publicly. The
service keeps only an index and the storage configuration.

That mode is out of scope for this snapshot — it needs a pod provisioned by the
intermediary and credentials issued by them. Everything documented here is the
stand-alone path, which is fully functional on its own.

## Endpoints (prEN 18222, Tables 17–19)

| Method (standard) | HTTP | Path |
|---|---|---|
| ReadDPPById | GET | `/dpp/v1/dpps/:dpp_id` |
| CreateDPP | POST | `/dpp/v1/dpps` |
| UpdateDPP (RFC 7396) | PATCH | `/dpp/v1/dpps/:dpp_id` |
| DeleteDPPById | DELETE | `/dpp/v1/dpps/:dpp_id` |
| ReadDPPByProductId | GET | `/dpp/v1/dppsByProductId/:product_id` |
| ReadDPPVersionByProductIdAndDate | GET | `/dpp/v1/dppsByProductIdAndDate/:product_id?date=` |
| ReadDPPIdsByProductIds | POST | `/dpp/v1/dppsByProductIds` |
| PostNewDPPToRegistry | POST | `/dpp/v1/registerDPP` |
| ReadDataElementCollection | GET | `/dpp/v1/dpps/:dpp_id/collections/:element_id` |
| UpdateDataElementCollection | PATCH | `/dpp/v1/dpps/:dpp_id/collections/:element_id` |
| ReadDataElement | GET | `/dpp/v1/dpps/:dpp_id/elements/*element_path` |
| UpdateDataElement | PATCH | `/dpp/v1/dpps/:dpp_id/elements/*element_path` |
| UPI short link | GET | `/p/:short_id` |

Identifiers used as a single path segment (`:dpp_id`, `:product_id`) must be
URL-encoded by the client. `*element_path` is a glob holding an absolute
ElementId path.

## How the standards map to the code

| Standard | Topic | Where in the app |
|---|---|---|
| prEN 18222 | API methods, status codes, Result object | routes, `app/controllers`, `ApiStatus` |
| prEN 18223 | DPP semantic model (payload) | `app/models/dpp.rb`, `docs/openapi.yaml` |
| prEN 18216 | Transport and formats (TLS, JSON) | `force_ssl`, response content types |
| prEN 18239 | Access rights and security | `TokenAuthenticatable` |
| prEN 18221 | Storage, archiving, versioning | `DppVersion`, `Dpp#archive_current_version!` |
| prEN 18219 | Unique identifiers, W3C DID | `DidOyd`, `did:oyd` and `did:web` |
| prEN 18246 | Authenticity and integrity | DID document as anchor |
| DIN DKE SPEC 99100 | Battery passport attributes | `db/seeds.rb` example content |

Errors return a **Result** object (`statusCode` plus `message[]`) per prEN 18222
Tables 13–16, mapped in `app/controllers/concerns/api_status.rb`.

## Tests

```bash
mkdir -p storage
RAILS_ENV=test bin/rails db:prepare
bundle exec rspec
```

## Open items before production use

1. **Auth profile (prEN 18239).** `TokenAuthenticatable` currently decodes the
   bearer token without verifying its signature. Wire it to your OIDC provider
   (JWKS, `iss`/`aud`/`exp`) and map roles to access rights.
2. **EC Registry client (prEN 18222 §5).** `registerDPP` returns a synthetic
   identifier; the real endpoint is defined by EU implementing acts.
3. **Content negotiation (prEN 18216 §5).** JSON is implemented; XML, JSON-LD
   and HTML renderers are not.
4. **Data dictionary (prEN 18223 §4.3).** The element-path resolver walks the
   document structurally instead of validating against a product-group
   dictionary.
5. **Data integrity (prEN 18246).** Signing and electronic attestation of
   attributes (EAA) are not implemented.

## License

[Apache 2.0 License 2026 - OwnYourData.eu](https://github.com/OwnYourData/dpp-service-public/blob/main/LICENSE)
