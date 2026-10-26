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

* Ruby **3.3.8** (see `.ruby-version`)
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
| `DPP_CORS_ORIGINS` | — (none) | origins, comma-separated, from which a browser may write. Reading is open to every origin |
| `DPP_RATE_LIMIT_READ` | `600` | reads per client address and minute; over it the answer is `429` with `Retry-After`. Counted in the database, so the limit holds across all replicas. When the count cannot be kept, the request goes through and the service logs a warning: the limit protects the service, and a struggling database is no reason to withhold public data |
| `DPP_RATE_LIMIT_WRITE` | `60` | writes per client address and minute, counted the same way |
| `DPP_MAX_PRODUCT_IDS` | `1000` | product identifiers one `ReadDPPIdsByProductIds` may name; more are answered with `400` |
| `RAILS_MAX_THREADS` | `5` | |
| `RAILS_LOG_LEVEL` | `info` | |
| `DPP_AUTH_MODE` | `permissive` | `did` enables signature verification of the bearer tokens and owner binding |
| `DPP_AUTH_AUDIENCE` | same as `DPP_SERVICE_ENDPOINT_BASE` | value the `aud` claim must carry |
| `DPP_FORCE_SSL` | `true` | redirect http to https. Right behind a proxy that terminates TLS, wrong on a machine with nothing in front of it — the compose file below switches it off |
| `DID_AUTH_CACHE_TTL` | `300` | how long a resolved public key stays valid |
| `DID_AUTH_MAX_LIFETIME` | `900` | longest accepted token lifetime in seconds |
| `DPP_SIGNATURE_RECHECK_INTERVAL` | `300` | seconds after which the key behind the signature of the economic operator is checked again on a read (docs/Integrity.md section 10) |
| `DPP_SIGNATURE_MAX_BYTES` | `5242880` | largest signature of the economic operator accepted, in bytes |
| `DPP_ACCESS_LOG_RETENTION_DAYS` | `1826` | days entries of the access log are kept; `bin/rails dpp:access:prune` removes older ones |
| `DPP_REQUEST_BINDING_FROM` | `2026-12-01` | in `did` mode, the first day on which a write is refused unless its token carries `rqh`. Before that day such a write is made, answered with `X-DPP-Request-Binding: missing;until="…"` and recorded as unbound (docs/Integrity.md section 11) |
| `DPP_WRITE_LOG_RETENTION_DAYS` | `3653` | days entries of the write log are kept at least; `bin/rails dpp:writes:prune` removes older ones, but none of a passport that exists or has a version kept |
| `DPP_AVAILABLE_SERVICES_URL` | — (none) | https URL of the JSON list of available DPP services shown on the start page; fetched at most once an hour; a list without `notice` is not taken, and when fetching fails the last good list stays. Without it the start page shows the list shipped in `config/available_services.json` |

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
(`DPP_AUTH_AUDIENCE`), `iat`, an `exp` at most 900 s after `iat` and after
now, and `jti`. Each token is accepted once: the service records issuer and
`jti` in the database until the token expires and refuses the same pair after
that, on every replica. A client therefore mints a token per request. The token
of a write also carries `rqh`, the hash over its method, request-target and body
(docs/Integrity.md section 11), so it holds for that one request only. A refused
token is answered with `401` and `WWW-Authenticate: Bearer error="invalid_token"`.
Before a write is made, the service keeps its token, together with what the
token binds, in the write log; `bin/rails dpp:writes:export DPP=<dppId>` gives
the entries of one passport, and `bin/verify_writes` checks them against the
public keys of the DIDs that signed them.
On top of that, only the DID that created a passport may update or delete it;
another DID is refused with `403` and `statusCode` `ClientForbidden`. Reading
the public part of a passport needs no token in either mode; in `did` mode the
controlled part goes only to its owner and to readers holding an access grant,
who present a token ([AccessClasses.md](AccessClasses.md) §8). A central
identity provider is not
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

The registry requires it to use `https` and to resolve to the passport, and the
service refuses one that does not. It imposes no maximum length — what a
carrier can bear is the economic operator's decision. Its host should belong to
the economic operator, not to whoever stores the passport; that is what lets
the passport move without a reprint.

This service does not serve the carrier path itself; `ReadDPPByProductId` is the
read path. Pointing the operator's host at a deployment that does serve it is
what makes the printed string resolvable.

---

## 4. With Docker

The image is published, so nothing has to be built: **`oydeu/dpp-service`**, for
`linux/amd64` and `linux/arm64`. Together with the `docker-compose.yml` in this
repository it brings its own PostgreSQL, runs the migrations once and starts.

```bash
curl -fsSLO https://raw.githubusercontent.com/OwnYourData/dpp-service-public/main/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/OwnYourData/dpp-service-public/main/.env.example
cp .env.example .env
```

Then open `.env` and fill in the three values it asks for — two generated
secrets and a database password. The file says how to generate them. Compose
refuses to start with a clear message if one is missing, rather than starting
with an improvised value that would be different after the next restart.

```bash
docker compose up -d
```

The service listens on `http://localhost:3000`, the Swagger UI is at
`http://localhost:3000/api-docs`.

```bash
docker compose logs -f service     what it is doing
docker compose down                stop it; the database volume is kept
docker compose pull && docker compose up -d    a newer version
```

Two things about that compose file are deliberate. The migration is a container
of its own that runs once and exits, because two service containers starting
together would otherwise run the migrations twice. And the service waits for
PostgreSQL to answer, not merely to listen — against a database that is up but
not ready, the migration fails and the container restarts in a loop that
explains nothing.

**The logs stay append-only on a fresh database too.** `bin/rails db:prepare`
loads `db/schema.rb` into an empty database instead of running the migrations,
and that file records tables but no triggers. Right after it, and after every
`bin/rails db:schema:load`, the service installs the PostgreSQL triggers that
refuse changes to the entries of the access log and the write log;
`bin/rails dpp:append_only:install` does the same by hand. On a database that
has them already, it only replaces them.

**Before the first passport**, set `DPP_SERVICE_ENDPOINT_BASE` in `.env` to the
address this instance will really be reachable at. It is written into the DID
document of every passport the service mints, and a DID's endpoint cannot be
changed afterwards.

**Before you put it on a network**, set `DPP_FORCE_SSL=true` in `.env` and put a
proxy with a certificate in front of it. The compose file turns that redirect off
so that `http://localhost:3000` answers at all; on a machine reachable from
outside, that is not what you want, and EN 18216:2026 §6.2 says so too.

**The proxy must speak HTTP/2 and report the client's version.** EN 18216:2026
clause 4 rules out HTTP versions older than HTTP/2 for DPP data exchange. TLS ends
at the proxy, so the service learns the version from the request header
`X-Client-Protocol`; with nginx that is
`proxy_set_header X-Client-Protocol $server_protocol;`. Requests below `/dpp/v1`
that arrived over HTTPS as HTTP/1.0 or HTTP/1.1 are then answered with `400`
(`http_version_not_supported`). The start page, `/api-docs`,
`/.well-known/dpp-service`, `/up` and `/version` stay open to every client.
Without the header nothing is refused.

### With your own database

If PostgreSQL is already running somewhere, the service is a single container:

```bash
docker run --rm -p 3000:3000 \
  -e RAILS_ENV=production \
  -e SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  -e KEY_VAULT_KEK="$(openssl rand -hex 32)" \
  -e DPP_DB_HOST=host.docker.internal \
  -e DPP_DB_NAME=dpp_service_production \
  -e DPP_DB_USER=postgres \
  -e DPP_DB_PASSWORD=postgres \
  -e DPP_SERVICE_ENDPOINT_BASE=https://dpp.example.org \
  oydeu/dpp-service:latest
```

Keep those two generated secrets — written like that they are new on every
start, which loses the sessions and, worse, the DID keys of every passport this
service minted itself.

Migrations do not run automatically on this path:

```bash
docker run --rm -e RAILS_ENV=production ... oydeu/dpp-service:latest bin/rails db:prepare
```

Building it yourself stays possible and is one command:

```bash
docker build -t dpp-service .
```

---

## 5. First run

Write access needs a bearer token, read access does not (EN 18239:2026).
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

Reading the public part needs no token.

### Updating

`UpdateDPP` expects a merge patch per RFC 7396:

```bash
curl -sS -X PATCH "$BASE/dpps/$EDID" \
  -H "Content-Type: application/merge-patch+json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"facilityId": "https://id.example.org/414/0952012345016"}' | jq -c '{facilityId, lastUpdated}'
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
* **No registry connection.** `registerDPP` checks the entry and answers `502`
  (`registryNotConnected`); nothing is registered. The Commission publishes no
  API specification for the EU DPP Registry.
* **Roles by access grant only.** Signature verification (`DPP_AUTH_MODE=did`),
  owner binding, access classes and reading per role are implemented
  (docs/AccessClasses.md). Who reads the controlled part is decided by access
  grants: an economic operator grants `legitimateInterest` for its own
  passports; `authority` is taken only from the issuers configured in
  `DPP_AUTHORITY_ISSUERS`. Every access to the controlled part is logged, and
  an issuer can revoke its grants (docs/AccessClasses.md §7, §10).
