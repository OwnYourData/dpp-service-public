# Stand-alone Operation

This guide describes the DPP Service as it runs **without any external
infrastructure**: the passport documents live in its own database, the service
serves them itself, and nothing beyond a PostgreSQL server is needed.

> OwnYourData operates a public instance at
> **https://dpp-service.ownyourdata.eu**. That instance does not store passport
> documents itself, but in a hosting pod of the data intermediary
> **[DID FlexCo](https://intermediary.at)**, which then also serves them
> publicly. That mode of operation needs a pod provided by the intermediary
> together with credentials and is not documented here. Everything that follows
> is the stand-alone path — it is fully functional.

---

## 1. Prerequisites

* Ruby **3.2.8** (see `.ruby-version`)
* PostgreSQL 14 or newer for production operation; for development and tests
  SQLite is sufficient, and it is already configured that way in
  `config/database.yml`
* optionally Docker, if you want to build the bundled image

Why PostgreSQL in production: the passport document is held as JSON in a
`jsonb` column, and the lookup by `uniqueProductIdentifier` runs over expression indexes on
it.

---

## 2. Setup

```bash
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

The service listens on `http://localhost:3000`, the Swagger UI is at
`http://localhost:3000/api-docs`.

The test suite needs a test database built once — there is no checked-in
`db/schema.rb`:

```bash
mkdir -p storage
RAILS_ENV=test bin/rails db:prepare
bundle exec rspec
```

---

## 3. Configuration

All settings come from environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `SECRET_KEY_BASE` | — | mandatory in production (Rails) |
| `KEY_VAULT_KEK` | derived from `SECRET_KEY_BASE` | key with which DID keys are stored encrypted |
| `DPP_DB_HOST` | `localhost` | PostgreSQL |
| `DPP_DB_NAME` | `dpp_service_production` | |
| `DPP_DB_USER` / `DPP_DB_PASSWORD` | — | |
| `DPP_SERVICE_ENDPOINT_BASE` | `https://dpp-service.ownyourdata.eu` | public base URL of this instance; written into the `serviceEndpoint` of the DID document |
| `OYDID_LOCATION` | `https://oydid.ownyourdata.eu` | registrar/VDR for `did:oyd` |
| `DPP_CORS_ORIGINS` | `*` | permitted origins for browser clients |
| `RAILS_MAX_THREADS` | `5` | |
| `RAILS_LOG_LEVEL` | `info` | |
| `DPP_AUTH_MODE` | `permissive` | `did` enables signature verification of the bearer tokens and owner binding |
| `DPP_AUTH_AUDIENCE` | same as `DPP_SERVICE_ENDPOINT_BASE` | value the `aud` claim must carry |
| `DID_AUTH_CACHE_TTL` | `300` | how long a resolved public key stays valid |
| `DID_AUTH_MAX_LIFETIME` | `900` | longest accepted token lifetime in seconds |

**Be sure to set `KEY_VAULT_KEK` before the first passport with a self-minted
DID is created.** Without the variable the service derives the key from
`SECRET_KEY_BASE` — whoever then rotates `SECRET_KEY_BASE` later makes all
stored DID keys unreadable and the affected passports irrevocable.

**`DPP_AUTH_MODE` is set to `permissive`** as long as nothing else is
configured. In this mode the bearer token is only decoded, not verified, and no
ownership is enforced: every caller may change every passport. That is
convenient for development and not safe for production.

For production operation set `did`: the token must then be a self-issued JWT,
EdDSA-signed with the document key of the issuer's `did:oyd`, carrying
`iss` = `sub` = the issuer's DID, `aud` = the base URL of this service
(`DPP_AUTH_AUDIENCE`), `iat`, an `exp` at most 900 s after `iat`, and `jti`.
On top of that, only the DID that created a passport may update or delete it;
another DID is refused with `403` and `statusCode` `ClientForbidden`. Reading
is public in both modes and needs no token. A central identity provider is not
needed for this — the service resolves the DID and checks against the public
key from the DID document.

Since 2026-08-17 the public instance operated by OwnYourData at
https://dpp-service.ownyourdata.eu runs in `did` mode. A stand-alone operator
gets `permissive` by default and should switch to `did` before going into
production.

To keep in mind when switching: passports created before have no recorded owner
and can no longer be changed afterwards.

**The ProductID is the unique product identifier.** EN 18219 cl. 3.22 defines
the UPI as *one* string that identifies the product and enables the web link to
the passport, and cl. 4.5.2 (1) requires that same string to be retrievable from
the data carrier. The service therefore issues no second token: what you send as
`uniqueProductIdentifier` is what is registered and what goes on the carrier.

The registry limits it to 50 characters over `https`, so the service refuses a
longer one at creation and says how many characters are over. Its host should
belong to the economic operator, not to whoever stores the passport — that is
what lets the passport move without a reprint.

This service does not serve the carrier path itself; `ReadDPPByProductId` is the
read path. Pointing the operator's host at a deployment that does serve it is
what makes the printed string resolvable.

---

## 4. With Docker

```bash
docker build -t dpp-service .
docker run --rm -p 3000:3000 \
  -e RAILS_ENV=production \
  -e SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  -e KEY_VAULT_KEK="$(openssl rand -hex 32)" \
  -e DPP_DB_HOST=host.docker.internal \
  -e DPP_DB_NAME=dpp_service_production \
  -e DPP_DB_USER=postgres \
  -e DPP_DB_PASSWORD=postgres \
  -e DPP_SERVICE_ENDPOINT_BASE=https://dpp.example.org \
  dpp-service
```

Migrations do not run automatically:

```bash
docker run --rm -e RAILS_ENV=production ... dpp-service bin/rails db:prepare
```

---

## 5. First run

Write access needs a bearer token, read access does not (prEN 18239).
With `DPP_AUTH_MODE=permissive` (the default) an unsigned token is sufficient —
for a first run that is enough:

```bash
b64() { printf %s "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
enc() { printf %s "$1" | jq -sRr @uri; }
BASE=http://localhost:3000/dpp/v1
TOKEN="$(b64 '{"alg":"none"}').$(b64 '{"sub":"did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS","scope":"dpp:write"}')."
PID="https://id.example.org/01/09520123456788"
```

### Create a passport, supplying the identifier yourself

Whoever already owns the identifier passes it along in the document. The
service then mints nothing and holds no key material. A `did:oyd` is the hash
over its own DID document, so the passport identifier and the operator
identifier below are unrelated values — neither is derived from the other, and
neither carries a path or suffix:

```bash
curl -sS -X POST "$BASE/dpps" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "digitalProductPassportId": "did:oyd:zQmSE1hzumtZ7AoK1qhHf4t5kiKsujMsJSHqoXtWrdd7K7W",
    "uniqueProductIdentifier": "https://id.example.org/01/09520123456788",
    "granularity": "model",
    "dppSchemaVersion": "EN 18223:2026",
    "economicOperatorId": "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
    "elements": [
      { "elementId": "EnergyPerformance", "objectType": "DataElementCollection", "elements": [
          { "objectType": "SingleValuedDataElement", "elementId": "LuminousFlux", "value": 806,
            "valueDataType": "xsd:integer", "unitOfMeasure": "lm" } ] }
    ] }' | jq .
```

A `did:oyd` supplied this way is checked before it is accepted: it has to
resolve, and the `serviceEndpoint` in its document has to name this instance —
`DPP_SERVICE_ENDPOINT_BASE`. Neither could be repaired afterwards, because the
service holds no key for a DID it did not mint. Identifiers that are not
`did:oyd` are stored as given.

The response contains `dppStatus`, `lastUpdated` and the `uniqueProductIdentifier` it was
created with. There is no separate `UPI` field: EN 18223 Table 1 defines none,
and the product identifier already is the unique product identifier.

### Create a passport, letting the identifier be minted

If `digitalProductPassportId` is missing, the service mints a `did:oyd` at the
registrar from `OYDID_LOCATION` and stores the private keys encrypted.
The `serviceEndpoint` of the DID document points to
`{DPP_SERVICE_ENDPOINT_BASE}/dpp/v1/dppsByProductId/{ProductID}`:

```bash
curl -sS -X POST "$BASE/dpps" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"uniqueProductIdentifier\": \"$PID\", \"granularity\": \"model\",
       \"dppSchemaVersion\": \"EN 18223:2026\",
       \"economicOperatorId\": \"did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS\"}" | jq -r .digitalProductPassportId
```

Note: the `serviceEndpoint` goes through the `uniqueProductIdentifier`, not through the DID.
The DID cannot appear in its own document — it is the hash over exactly this
document.

### Reading

```bash
DID="did:oyd:zQmSE1hzumtZ7AoK1qhHf4t5kiKsujMsJSHqoXtWrdd7K7W"
EDID=$(enc "$DID"); EPID=$(enc "$PID")

curl -sS "$BASE/dpps/$EDID" | jq -c '{digitalProductPassportId, dppStatus, uniqueProductIdentifier}'
curl -sS "$BASE/dppsByProductId/$EPID" | jq -r .digitalProductPassportId
curl -sS "$BASE/dpps/$EDID/collections/EnergyPerformance" | jq -c '{ElementId, Name}'
curl -sS "$BASE/dpps/$EDID/elements/EnergyPerformance/LuminousFlux" | jq -c '{Value, UnitOfMeasure}'
```

Reading needs no token.

### Updating

`UpdateDPP` expects a merge patch per RFC 7396:

```bash
curl -sS -X PATCH "$BASE/dpps/$EDID" \
  -H "Content-Type: application/merge-patch+json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"facilityId": "https://id.example.org/414/0952012345002"}' | jq -c '{facilityId, lastUpdated}'
```

Every update archives the previous state in `dpp_versions`. The state at a
given point in time can thus be retrieved (EN 18221:2026, module 6):

```bash
curl -sS "$BASE/dppsByIdAndDate/$EDID?date=2026-01-01T00:00:00Z" | jq .
```

### Deleting

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$BASE/dpps/$EDID" \
  -H "Authorization: Bearer $TOKEN"
```

Answers with `204`. The active passport disappears, the last state is kept in
`dpp_versions` with `dppStatus: "Archived"` — EN 18221:2026 4.2 requires that.
If the service minted the DID itself, it revokes it at the registrar in the
process.

---

## 6. What stand-alone operation does not cover

* **No data intermediary.** The header `X-DPP-Storage`, with which an
  individual passport is placed in a hosting pod, remains unused. Without it
  the service stores locally — that is the default and needs no configuration.
* **No registry connection.** `registerDPP` returns a synthetic identifier; the
  real endpoint is defined by EU implementing acts.
* **No role model.** Signature verification (`DPP_AUTH_MODE=did`) and owner
  binding are implemented. The roles from prEN 18239 — authority, refurbisher,
  consumer — and the distinction between public data, controlled data and trade
  secrets are missing. There are two levels: publicly readable, and writable by
  the owner.
