# Stand-alone Betrieb

Diese Anleitung beschreibt den DPP Service so, wie er **ohne jede externe
Infrastruktur** läuft: die Passdokumente liegen in der eigenen Datenbank, der
Dienst liefert sie selbst aus, und ausser einem PostgreSQL-Server wird nichts
benötigt.

> OwnYourData betreibt unter **https://dpp-service.ownyourdata.eu** eine
> öffentliche Instanz. Die speichert Passdokumente nicht selbst, sondern in
> einem Hosting-Pod des Datenvermittlers **DID FlexCo**, der sie dann auch
> öffentlich ausliefert. Dieser Betriebsmodus braucht einen vom Vermittler
> bereitgestellten Pod samt Zugangsdaten und ist hier nicht dokumentiert.
> Alles Folgende ist der eigenständige Weg — er ist vollständig funktionsfähig.

---

## 1. Voraussetzungen

* Ruby **3.2.8** (siehe `.ruby-version`)
* PostgreSQL 14 oder neuer für den Produktivbetrieb; für Entwicklung und Tests
  genügt SQLite, das ist in `config/database.yml` bereits so hinterlegt
* optional Docker, wenn du das mitgelieferte Image bauen willst

Warum PostgreSQL im Produktivbetrieb: das Passdokument wird als JSON in einer
`jsonb`-Spalte gehalten, und die Suche über `ProductID` und `short_id` läuft
über Ausdrucks-Indizes darauf.

---

## 2. Einrichten

```bash
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Der Dienst hört auf `http://localhost:3000`, die Swagger-Oberfläche liegt unter
`http://localhost:3000/api-docs`.

Die Testsuite braucht eine einmal aufgebaute Testdatenbank — es gibt keine
eingecheckte `db/schema.rb`:

```bash
mkdir -p storage
RAILS_ENV=test bin/rails db:prepare
bundle exec rspec
```

---

## 3. Konfiguration

Alle Einstellungen kommen aus Umgebungsvariablen.

| Variable | Vorgabe | Bedeutung |
|---|---|---|
| `SECRET_KEY_BASE` | — | Pflicht in Produktion (Rails) |
| `KEY_VAULT_KEK` | aus `SECRET_KEY_BASE` abgeleitet | Schlüssel, mit dem DID-Schlüssel verschlüsselt abgelegt werden |
| `DPP_DB_HOST` | `localhost` | PostgreSQL |
| `DPP_DB_NAME` | `dpp_service_production` | |
| `DPP_DB_USER` / `DPP_DB_PASSWORD` | — | |
| `DPP_SERVICE_ENDPOINT_BASE` | `https://dpp-service.ownyourdata.eu` | öffentliche Basis-URL dieser Instanz; wird in den `serviceEndpoint` des DID-Dokuments geschrieben |
| `DPP_UPI_BASE_URL` | `https://r.oydapp.eu/p` | Basis des Kurzlinks für die EU-Registry |
| `OYDID_LOCATION` | `https://oydid.ownyourdata.eu` | Registrar/VDR für `did:oyd` |
| `DPP_CORS_ORIGINS` | `*` | erlaubte Ursprünge für Browser-Clients |
| `RAILS_MAX_THREADS` | `5` | |
| `RAILS_LOG_LEVEL` | `info` | |

**`KEY_VAULT_KEK` unbedingt setzen, bevor der erste Pass mit selbst geprägter
DID angelegt wird.** Ohne die Variable leitet der Dienst den Schlüssel aus
`SECRET_KEY_BASE` ab — wer dann später `SECRET_KEY_BASE` rotiert, macht damit
alle gespeicherten DID-Schlüssel unlesbar und die betroffenen Pässe
unwiderrufbar.

**`DPP_UPI_BASE_URL` kurz halten.** Die EU-Registry begrenzt den Unique Product
Identifier auf 50 Zeichen. Der Dienst hängt einen zwölfstelligen `short_id` an,
also bleiben für die Basis höchstens 37 Zeichen. Die Basis muss `https` sein und
direkt mit `200` antworten, ohne Weiterleitung.

---

## 4. Mit Docker

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
  -e DPP_UPI_BASE_URL=https://dpp.example.org/p \
  dpp-service
```

Migrationen laufen nicht automatisch mit:

```bash
docker run --rm -e RAILS_ENV=production ... dpp-service bin/rails db:prepare
```

---

## 5. Erster Durchlauf

Schreibende Zugriffe brauchen ein Bearer-Token, lesende nicht (prEN 18239).
Die Signaturprüfung ist noch ein Platzhalter — siehe die offenen Punkte im
README. Für einen ersten Test genügt ein unsigniertes Token:

```bash
b64() { printf %s "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
enc() { printf %s "$1" | jq -sRr @uri; }
BASE=http://localhost:3000/dpp/v1
TOKEN="$(b64 '{"alg":"none"}').$(b64 '{"sub":"did:web:example.org","scope":"dpp:write"}')."
PID="https://id.example.org/01/09520123456788"
```

### Pass anlegen, Identifier selbst mitgeben

Wer den Identifier bereits besitzt, gibt ihn im Dokument mit. Der Dienst prägt
dann nichts und hält kein Schlüsselmaterial:

```bash
curl -sS -X POST "$BASE/dpps" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "DigitalProductPassportID": "did:web:example.org:dpp:0001",
    "ProductID": "https://id.example.org/01/09520123456788",
    "Granularity": "model",
    "DPPSchemaVersion": "prEN 18223:2025",
    "EconomicOperatorID": "did:web:example.org",
    "dataElementCollections": [
      { "ElementId": "EnergyPerformance", "Name": "Energy performance",
        "DataElements": [
          { "@type": "SinglevaluedDataElement", "ElementId": "LuminousFlux",
            "Name": "Luminous flux", "Value": 806,
            "ValueDataType": "xs:integer", "UnitOfMeasure": "lm" } ] }
    ] }' | jq .
```

Die Antwort enthält `DPPStatus`, `LastUpdate` und `UPI` — den Kurzlink, der bei
der EU-Registry gemeldet wird.

### Pass anlegen, Identifier prägen lassen

Fehlt `DigitalProductPassportID`, prägt der Dienst eine `did:oyd` beim
Registrar aus `OYDID_LOCATION` und legt die privaten Schlüssel verschlüsselt ab.
Der `serviceEndpoint` des DID-Dokuments zeigt auf
`{DPP_SERVICE_ENDPOINT_BASE}/dpp/v1/dppsByProductId/{ProductID}`:

```bash
curl -sS -X POST "$BASE/dpps" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"ProductID\": \"$PID\", \"Granularity\": \"model\",
       \"DPPSchemaVersion\": \"prEN 18223:2025\",
       \"EconomicOperatorID\": \"did:web:example.org\"}" | jq -r .DigitalProductPassportID
```

Beachte: der `serviceEndpoint` läuft über die `ProductID`, nicht über die DID.
Die DID kann im eigenen Dokument nicht vorkommen — sie ist der Hash über genau
dieses Dokument.

### Lesen

```bash
DID="did:web:example.org:dpp:0001"
EDID=$(enc "$DID"); EPID=$(enc "$PID")

curl -sS "$BASE/dpps/$EDID" | jq -c '{DigitalProductPassportID, DPPStatus, UPI}'
curl -sS "$BASE/dppsByProductId/$EPID" | jq -r .DigitalProductPassportID
curl -sS "$BASE/dpps/$EDID/collections/EnergyPerformance" | jq -c '{ElementId, Name}'
curl -sS "$BASE/dpps/$EDID/elements/dataElementCollections/EnergyPerformance/DataElements/LuminousFlux" | jq -c '{Value, UnitOfMeasure}'
```

Lesen braucht kein Token. Der Kurzlink liegt ausserhalb von `/dpp/v1` und
antwortet direkt mit `200`, ohne Weiterleitung:

```bash
curl -sS http://localhost:3000/p/<short_id>
```

### Ändern

`UpdateDPP` erwartet einen Merge Patch nach RFC 7396:

```bash
curl -sS -X PATCH "$BASE/dpps/$EDID" \
  -H "Content-Type: application/merge-patch+json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"FacilityID": "https://id.example.org/414/0952012345002"}' | jq -c '{FacilityID, LastUpdate}'
```

Jede Änderung archiviert den vorherigen Stand in `dpp_versions`. Der Stand zu
einem Zeitpunkt ist damit abrufbar (prEN 18221, Modul 6):

```bash
curl -sS "$BASE/dppsByProductIdAndDate/$EPID?date=2026-01-01T00:00:00Z" | jq .
```

### Löschen

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$BASE/dpps/$EDID" \
  -H "Authorization: Bearer $TOKEN"
```

Antwortet mit `204`. Der aktive Pass verschwindet, der letzte Stand bleibt mit
`DPPStatus: "Archived"` in `dpp_versions` erhalten — das verlangt prEN 18221.
Hat der Dienst die DID selbst geprägt, widerruft er sie dabei beim Registrar.

---

## 6. Was der Stand-alone-Betrieb nicht abdeckt

* **Kein Datenvermittler.** Der Header `X-DPP-Storage`, mit dem ein einzelner
  Pass in einem Hosting-Pod abgelegt wird, bleibt ungenutzt. Ohne ihn speichert
  der Dienst lokal — das ist die Vorgabe und erfordert keine Konfiguration.
* **Keine Registry-Anbindung.** `registerDPP` liefert eine synthetische
  Kennung; der echte Endpunkt wird durch EU-Durchführungsrechtsakte definiert.
* **Keine produktionsreife Authentifizierung.** Siehe die offenen Punkte im
  README.
