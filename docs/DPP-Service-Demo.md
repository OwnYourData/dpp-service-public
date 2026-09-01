# DPP Service auf der Kommandozeile

**Technical Integration Meeting, PACE-DPP** — Live-Demo, ca. 15 Minuten.

Der rote Faden ist eine Frage: *Wem gehört der Produktpass?* Wir fangen beim
bequemsten Weg an, bei dem der Dienstleister alles macht, und holen uns in zwei
Schritten die Kontrolle zurück — zuerst über die **Schlüssel**, dann über den
**Speicherort**. Am Ende steht ein Pass, der unter einer eigenen Domain
abrufbar ist, dessen Kennung dem Wirtschaftsteilnehmer gehört und dessen Daten
bei einem registrierten Datenintermediär liegen.

Alle Befehle laufen gegen die produktive Installation.

Zwei Hilfsskripte unter `tmp/` prägen das Token und die Vollmacht. Sie signieren
mit dem privaten Schlüssel des Wirtschaftsteilnehmers und liegen deshalb nicht
in diesem Repository — jede andere Signierumgebung leistet dasselbe, das Format
steht in `docs/Delegation.md`.

| | |
|---|---|
| DPP Service | `https://dpp-service.ownyourdata.eu` |
| Verwahrer (Datenintermediär) | `https://dpp.go-data.at`, Collection 36 |
| Domain des Wirtschaftsteilnehmers | `dpp.oydapp.eu` |
| VDR / Registrar für `did:oyd` | `https://oydid.ownyourdata.eu` |

> **Zu den Namen.** Die vier Zeilen sind vier **Rollen**, nicht vier Produkte
> desselben Hauses. `dpp.oydapp.eu` ist die Domain des Wirtschaftsteilnehmers —
> sie gehört ihm, nicht dem Dienst, und der Dienst hat auf sie keinen Zugriff.
> Dass hinter mehreren dieser Rollen zufällig dieselbe Organisation steht, ist
> die einzige Vereinfachung dieser Demo; die Trennung, um die es geht, ist
> trotzdem eine echte — sie ist an jeder Stelle nachprüfbar, an der gleich ein
> Hostname mit einem anderen verglichen wird.

**Wer was hält.** Drei Akteure, und in jedem Schritt verschiebt sich, wer welche
Information hat. Dieselbe Skizze steht nach Schritt 1, 3 und 5 noch einmal da;
`▸` markiert, was der jeweilige Schritt geändert hat.

```
┌─ WIRTSCHAFTSTEILNEHMER ────────────────── dpp.oydapp.eu ─┐
│ Identitätsschlüssel  ·  DNS-Zone                         │
│ Passschlüssel, sobald er selbst prägt                    │
└──────────────────────────────────────────────────────────┘
        │  Token, selbst signiert
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadaten je Pass  ·  Vollmacht im Klartext              │
│ Nutzdaten nur, solange kein Verwahrer benannt ist        │
└──────────────────────────────────────────────────────────┘
        │  Vollmacht im Header X-DPP-Storage
        ▼
┌─ VERWAHRER (Intermediär) ─────────────── dpp.go-data.at ─┐
│ Nutzdaten  ·  Historie  ·  Zugriffslog                   │
│ kennt den Pass nur als Objekt, nicht als Pass            │
└──────────────────────────────────────────────────────────┘
```

---

## 0 — Vorbereitung

```bash
cd ~/projects/pace-dpp/impl/dpp-service
BASE="https://dpp-service.ownyourdata.eu/dpp/v1"
EO="did:oyd:zQmX493GLVxE8Wasc8ANTdZmq4YUsvdk5j6Daf7iQaPECt6"
curl -sS -o /dev/null -w 'Service: %{http_code}\n' https://dpp-service.ownyourdata.eu/up
curl -sS https://dpp-service.ownyourdata.eu/.well-known/dpp-service | jq .
```

Erwartet:

```json
{
  "did": "did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd",
  "audience": "https://dpp-service.ownyourdata.eu"
}
```

> Der Dienst sagt öffentlich, wer er ist. Diese DID braucht man später, um eine
> Vollmacht auf ihn auszustellen — und sie ist der Grund, warum kein geteiltes
> Geheimnis nötig ist.

**Das Token.** Schreibzugriffe brauchen ein Bearer-Token, das der
Wirtschaftsteilnehmer sich **selbst ausstellt** und mit seinem Identitäts­schlüssel
signiert. Es gibt keine Registrierung und kein vom Dienst vergebenes Passwort.

```bash
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
echo "$TOKEN" | cut -d. -f2 | ruby -rbase64 -e 's = STDIN.read.strip; print Base64.urlsafe_decode64(s + "=" * ((4 - s.size % 4) % 4))' | jq .
```

Erwartet: `iss` und `sub` sind die DID des Wirtschaftsteilnehmers, `aud` ist der
Dienst.

> Tokens sind kurzlebig — deshalb steht diese Zeile vor jedem schreibenden
> Aufruf noch einmal.

> **Merksatz für später:** das hier ist der *Identitätsschlüssel* des
> Wirtschaftsteilnehmers. Der *Passschlüssel* ist etwas anderes — den haben wir
> gleich noch nicht.

---

## 1 — Der bequeme Weg: der Dienst macht alles

Wir legen einen Pass an und geben **keine** Passkennung und **keinen**
Speicherort mit.

```bash
PID1="https://dpp.oydapp.eu/01/09520123456788/21/000901"
curl -sS -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d @- <<JSON | jq .
{
  "uniqueProductIdentifier": "$PID1",
  "granularity": "item",
  "dppSchemaVersion": "EN 18223:2026",
  "economicOperatorId": "$EO",
  "elements": [
    { "elementId": "ProductIdentification",
      "objectType": "DataElementCollection",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "ModelIdentifier", "value": "LUM-A60-827-806", "valueDataType": "xsd:string" },
        { "objectType": "SingleValuedDataElement", "elementId": "BrandName", "value": "Lumina", "valueDataType": "xsd:string" }
      ] }
  ]
}
JSON
```

Erwartet: `201`, und in der Antwort steht eine **frisch geprägte**
`digitalProductPassportId` — die hat der Dienst gemacht, nicht wir.

Damit liegen zwei Kennungen vor, und es lohnt sich, gleich hier zu zeigen, wie
sie zusammenhängen:

```
   Datenträger (QR, NFC)
        │   trägt GENAU EINE Zeichenkette
        ▼
   uniqueProductIdentifier   https://dpp.oydapp.eu/01/09520123456788/21/000901
        │                      └─ Host: Wirtschaftsteilnehmer
        │                                   └─ Pfad: Schema A oder B
        │   DNS-Eintrag, keine Weiterleitung
        ▼
   Verwahrer           in Schritt 1 noch der Dienst selbst
        ▼
   Pass-Dokument       uniqueProductIdentifier · digitalProductPassportId ─▶ ①
        │              economicOperatorId ──▶ ②  ·  facilityId
        │              granularity · dppSchemaVersion · dppStatus · lastUpdated
        │   DID-Auflösung
        ▼
   DID-Dokumente       ① Pass:      serviceEndpoint, publicKeyMultibase
                       ② Betreiber: publicKeyMultibase
```

**Die Produkt-ID ist die Adresse, die Pass-ID ist die Identität.** Gelesen wird
über die Adresse — ein Scan, kein Resolver, kein Redirect. Alles, was
Verantwortung zuordnet — Schreiben, Delegieren, Widerrufen, Versionieren —
hängt an der Identität.

Lesen lässt er sich sofort:

```bash
ENC1=$(printf %s "$PID1" | jq -sRr @uri)
curl -sS "$BASE/dppsByProductId/$ENC1" | jq -c 'if .digitalProductPassportId then {digitalProductPassportId, uniqueProductIdentifier, granularity, dppStatus} else . end'
```

### Was wir dabei aus der Hand gegeben haben

```bash
DID1=$(curl -sS "$BASE/dppsByProductId/$ENC1" | jq -r .digitalProductPassportId)
curl -sS "https://oydid.ownyourdata.eu/1.0/identifiers/$DID1" | jq -c '.service[0].serviceEndpoint'
curl -sS -o /dev/null -w 'Traeger unter eigener Domain: %{http_code}\n' "$PID1"
```

Erwartet: der `serviceEndpoint` zeigt auf **`dpp-service.ownyourdata.eu`**, und
der Träger unter der eigenen Domain liefert **404**.

> **Eine Abhängigkeit, zwei Auswirkungen.**
> 1. Die Passkennung wurde vom Dienst geprägt — er hält `documentKey` und
>    `revocationKey`. Er kann die Kennung widerrufen und das DID-Dokument
>    ändern; der Wirtschaftsteilnehmer kann in dieser Konfiguration beides
>    nicht.
> 2. Deshalb steht auch fest, wohin ein Leser geschickt wird: der
>    `serviceEndpoint` zeigt auf den Dienst, und umlenken kann ihn nur, wer den
>    Schlüssel hat.
>
> Der 404 unter der eigenen Domain zeigt nur, dass dort **gerade** nichts
> ausgeliefert wird — nicht, dass dort nichts stehen dürfte. Die Daten gehören
> dem Wirtschaftsteilnehmer, und niemand hindert ihn, sie unter seiner Domain zu
> veröffentlichen. Was er ohne den Dienst nicht kann, ist, diese Veröffentlichung
> zum *Pass* zu machen: nichts signiert sie, keine Historie hängt daran, und wer
> die Passkennung auflöst, landet trotzdem beim Dienst.
>
> Der praktische Preis: wegziehen geht in dieser Variante nur mit dem
> Entgegenkommen des Dienstes — oder mit einer neuen Passkennung. Der gedruckte
> Träger überlebt das, die Identität nicht.

**Stand nach diesem Schritt.**

```
┌─ WIRTSCHAFTSTEILNEHMER ────────────────── dpp.oydapp.eu ─┐
│ Identitätsschlüssel                                      │
└──────────────────────────────────────────────────────────┘
        │  Token
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadaten je Pass                                        │
│ ▸ Passkennung, documentKey, revocationKey                │
│ ▸ Nutzdaten                                              │
└──────────────────────────────────────────────────────────┘
        ·  Verwahrer noch nicht beteiligt
```

---

## 2 — Zwischenspiel: die zwei Kennungen

Die Skizze aus Schritt 1 in einer Tabelle — dieselbe Unterscheidung, nur nach
Eigenschaften sortiert:

| | Produkt-ID | Pass-ID |
|---|---|---|
| identifiziert | das Produkt | das Dokument darüber |
| steht auf dem Träger | ja | nie |
| ändert sich | nie, sobald gedruckt | bei jeder Dokumentänderung |
| trägt Schlüssel | nein | ja — signieren, widerrufen, versionieren |
| gebraucht für | Lesen | Schreiben, Register, Sicherungskopie, Historie |

> Warum der `serviceEndpoint` über die Produktkennung läuft: eine `did:oyd` ist
> der Hash über ihr eigenes Dokument. Eine Adresse, die die DID enthielte, wäre
> Teil ihrer eigenen Berechnung.
>
> Und warum es beide braucht: EN 18222 Abschn. 4.5 liefert zu einer
> Produktkennung eine **Liste** von Passkennungen (`0..*`) — die von ESPR
> Art. 10(4) verlangte Sicherungskopie ist der Alltagsfall.

---

## 3 — Kontrolle über die Schlüssel: eigene Passkennung

Wir prägen die Passkennung selbst, beim VDR, und behalten beide Schlüssel.
Wichtig ist der `serviceEndpoint`: er muss den Host nennen, der den Pass
**tatsächlich ausliefern wird** — hier noch der Dienst selbst.

```bash
PID2="https://dpp.oydapp.eu/01/09520123456788/21/000902"
ENC2=$(printf %s "$PID2" | jq -sRr @uri)
RESP=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"https://dpp-service.ownyourdata.eu/dpp/v1/dppsByProductId/$ENC2\"}]},\"options\":{\"key_type\":\"ed25519\"}}")
DID2=$(echo "$RESP" | jq -r '.didState.did')
echo "$RESP" | jq '.didState.secret'
echo "DID2 = $DID2"
```

> ⚠️ `documentKey` und `revocationKey` kommen **in dieser einen Antwort** zurück
> und werden nirgends gespeichert. Wer sie behält, dem gehört die Kennung.

Damit anlegen — der Dienst prägt jetzt nichts mehr:

```bash
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d @- <<JSON | jq -c 'if .digitalProductPassportId then {digitalProductPassportId, uniqueProductIdentifier, dppStatus} else . end'
{
  "digitalProductPassportId": "$DID2",
  "uniqueProductIdentifier": "$PID2",
  "granularity": "item",
  "dppSchemaVersion": "EN 18223:2026",
  "economicOperatorId": "$EO",
  "elements": [
    { "elementId": "ProductIdentification",
      "objectType": "DataElementCollection",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "ModelIdentifier", "value": "LUM-A60-827-806", "valueDataType": "xsd:string" }
      ] }
  ]
}
JSON
```

Erwartet: `201`, und die **gelieferte Kennung kommt unverändert zurück**.

### Die Prüfung, die dabei läuft

Der Dienst hält für eine fremd geprägte DID keinen Schlüssel — er kann ein
falsches DID-Dokument später also nicht reparieren. Deshalb prüft er **vor**
allem Dauerhaften, ob die Kennung auflöst und ob ihr `serviceEndpoint` den
richtigen Host nennt. Zum Vorführen absichtlich falsch:

```bash
PIDX="https://dpp.oydapp.eu/01/09520123456788/21/000999"
ENCX=$(printf %s "$PIDX" | jq -sRr @uri)
DIDX=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"https://dpp.data-vault.eu/dpp/v1/dppsByProductId/$ENCX\"}]},\"options\":{\"key_type\":\"ed25519\"}}" | jq -r '.didState.did')
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -w '\nHTTP %{http_code}\n' -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d "{\"digitalProductPassportId\":\"$DIDX\",\"uniqueProductIdentifier\":\"$PIDX\",\"granularity\":\"item\",\"dppSchemaVersion\":\"EN 18223:2026\",\"economicOperatorId\":\"$EO\"}"
```

Erwartet: **`HTTP 400`**, und die Meldung nennt **beide** Hostnamen im Klartext:

```
digitalProductPassportId resolves to dpp.data-vault.eu,
but this passport is served from dpp-service.ownyourdata.eu
```

Es wird nichts angelegt. Verglichen wird nur der **Host**, nie der Pfad — geprüft
wird, wohin ein Leser geschickt wird.

**Stand nach diesem Schritt.**

```
┌─ WIRTSCHAFTSTEILNEHMER ────────────────── dpp.oydapp.eu ─┐
│ Identitätsschlüssel                                      │
│ ▸ documentKey und revocationKey des Passes               │
└──────────────────────────────────────────────────────────┘
        │  Token  +  fertige Passkennung
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadaten je Pass  ·  Nutzdaten                          │
│ ▸ kein Schlüssel zur Passkennung                         │
└──────────────────────────────────────────────────────────┘
        ·  Verwahrer noch nicht beteiligt
```

---

## 4 — Kontrolle über den Speicherort: Intermediär und DNS

Zwei Dinge sind nötig, und sie sind unabhängig voneinander.

**Erstens der Name.** `dpp.oydapp.eu` gehört dem Wirtschaftsteilnehmer und zeigt
per DNS auf den Verwahrer:

```bash
dig +short dpp.oydapp.eu
```

Erwartet: `89.58.20.114` — die Adresse des Verwahrers. Der Verwahrer liefert
also unter einem Namen aus, der ihm **nicht gehört**. Nichts wird weitergeleitet;
ein Wechsel des Verwahrers ist ein Eintrag in der eigenen Zone, kein Neudruck.

**Zweitens die Vollmacht.** Der Wirtschaftsteilnehmer stellt sie selbst aus und
signiert sie; sie nennt Delegatar, Verwahrer, Collection, Produkt, erlaubte
Operationen und Zweck. Der Dienst reicht sie im Header `X-DPP-Storage` weiter —
**nicht** als Feld im Pass, denn ein proprietäres Attribut im Dokument würde die
EN-18223-Konformität für jeden Leser brechen.

```bash
PID3="https://dpp.oydapp.eu/01/09520123456788/21/000903"
DELEG=$(SERVICE_DID="did:oyd:zQmZBWgKreVE9VK4fxxU9RrkQ6LzcryfU15tFgDvtgtBbZd" POD_BASE="https://dpp.go-data.at" COLLECTION_ID=36 PRODUCT_ID="$PID3" bundle exec ruby tmp/mint_delegation.rb 2>/dev/null)
STORAGE="{\"base_url\":\"https://dpp.go-data.at\",\"collection_id\":\"36\",\"delegation\":\"$DELEG\"}"
echo "$DELEG" | cut -d. -f2 | ruby -rbase64 -e 's = STDIN.read.strip; print Base64.urlsafe_decode64(s + "=" * ((4 - s.size % 4) % 4))' | jq .
```

Erwartet: der Inhalt der Vollmacht im Klartext — Aussteller, Delegatar,
Verwahrer, Collection, Produkt, Zweck, Laufzeit, Replay-Kennung.

> Was der Dienst speichert, ist damit **kein Zugangsschlüssel** mehr. Die
> Vollmacht nennt ihren Delegatar namentlich und ist ohne dessen privaten
> Schlüssel wirkungslos. Ein Anbieter, der für viele Wirtschaftsteilnehmer
> arbeitet, hielte sonst ein Geheimnis pro Kunde.

---

## 5 — Alles zusammen

Eigene Kennung, eigener Name, Speicherung beim Intermediär. Der
`serviceEndpoint` nennt jetzt die Langform **beim Verwahrer**.

```bash
ENC3=$(printf %s "$PID3" | jq -sRr @uri)
RESP3=$(curl -sS -X POST https://oydid.ownyourdata.eu/1.0/create -H "Content-Type: application/json" \
  -d "{\"didDocument\":{\"service\":[{\"type\":\"DigitalProductPassport\",\"serviceEndpoint\":\"https://dpp.go-data.at/dpp/v1/dppsByProductId/$ENC3\"}]},\"options\":{\"key_type\":\"ed25519\"}}")
DID3=$(echo "$RESP3" | jq -r '.didState.did')
echo "$RESP3" | jq '.didState.secret'
echo "DID3 = $DID3"
```

```bash
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -X POST "$BASE/dpps" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-DPP-Storage: $STORAGE" -d @- <<JSON | jq -c 'if .digitalProductPassportId then {digitalProductPassportId, uniqueProductIdentifier, granularity, dppStatus} else . end'
{
  "digitalProductPassportId": "$DID3",
  "uniqueProductIdentifier": "$PID3",
  "granularity": "item",
  "dppSchemaVersion": "EN 18223:2026",
  "economicOperatorId": "$EO",
  "elements": [
    { "elementId": "ProductIdentification",
      "objectType": "DataElementCollection",
      "dictionaryReference": "https://dict.example.org/dpp/lighting/ProductIdentification",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "ModelIdentifier", "value": "LUM-A60-827-806", "valueDataType": "xsd:string" },
        { "objectType": "SingleValuedDataElement", "elementId": "BrandName", "value": "Lumina", "valueDataType": "xsd:string" },
        { "objectType": "SingleValuedDataElement", "elementId": "SerialNumber", "value": "000903", "valueDataType": "xsd:string" }
      ] },
    { "elementId": "EnergyPerformance",
      "objectType": "DataElementCollection",
      "dictionaryReference": "https://dict.example.org/dpp/lighting/EnergyPerformance",
      "elements": [
        { "objectType": "SingleValuedDataElement", "elementId": "OnModePower", "value": 8.5, "valueDataType": "xsd:decimal", "unitOfMeasure": "W" },
        { "objectType": "SingleValuedDataElement", "elementId": "LuminousFlux", "value": 806, "valueDataType": "xsd:integer", "unitOfMeasure": "lm" }
      ] }
  ]
}
JSON
```

### Der Moment, auf den die ganze Demo hinausläuft

```bash
curl -sS "https://dpp.oydapp.eu/01/09520123456788/21/000903" | jq .
```

**Ein Aufruf. Kein Token, kein Auflösungsdienst, keine Weiterleitung.** Genau die
Zeichenkette, die auf dem Produkt steht, liefert den Pass — das verlangt
EN 18219:2026 Abschn. 4.5.2 (1).

Und die drei Kontrollen, jede einzeln nachweisbar:

```bash
echo "--- die Kennung gehoert uns: der Dienst hat sie nicht gepraegt ---"
curl -sS "https://oydid.ownyourdata.eu/1.0/identifiers/$DID3" | jq -c '.service[0].serviceEndpoint'
echo "--- beide liefern aus, aber nur einer speichert ---"
curl -sS -o /dev/null -w 'Verwahrer: %{http_code}\n' "https://dpp.go-data.at/dpp/v1/dppsByProductId/$ENC3"
curl -sS -o /dev/null -w 'Dienst:    %{http_code}\n' "$BASE/dppsByProductId/$ENC3"
echo "--- und der Verwahrer liefert NICHT unter seinem eigenen Namen aus ---"
curl -sS -o /dev/null -w 'gleicher Pfad bei dpp.go-data.at: %{http_code}\n' "https://dpp.go-data.at/01/09520123456788/21/000903"
```

Erwartet: `serviceEndpoint` nennt den Verwahrer; **beide** antworten `200`; und
der Trägerpfad unter dem Namen des Verwahrers `404`.

> Dass auch der Dienst `200` liefert, ist kein Widerspruch: bei einem Pass beim
> Verwahrer hält er den Inhalt nicht vor, sondern liest ihn bei jedem Zugriff
> dort nach (`Dpp#document_content` → `pod_storage.read_payload`). Er bleibt
> Durchreiche — nimmt man ihm die Vollmacht, hat er nichts mehr auszuliefern.

> Die letzte Zeile ist die wichtigste: der Pfad ist der Suchschlüssel, aber der
> Host muss der des Wirtschaftsteilnehmers sein. Sonst könnte ein Verwahrer den
> Pass unter seiner eigenen Domain ausliefern und sich still zur Adresse auf dem
> Produkt machen.

**Stand nach diesem Schritt.**

```
┌─ WIRTSCHAFTSTEILNEHMER ────────────────── dpp.oydapp.eu ─┐
│ Identitätsschlüssel  ·  Passschlüssel                    │
│ ▸ DNS-Zone zeigt auf den Verwahrer                       │
└──────────────────────────────────────────────────────────┘
        │  Token  +  Passkennung  +  Vollmacht
        ▼
┌─ DPP SERVICE ─────────────── dpp-service.ownyourdata.eu ─┐
│ Metadaten je Pass  ·  Vollmacht im Klartext              │
│ ▸ keine Nutzdaten mehr, liest sie durch                  │
└──────────────────────────────────────────────────────────┘
        │  Vollmacht im Header X-DPP-Storage
        ▼
┌─ VERWAHRER ───────────────────────────── dpp.go-data.at ─┐
│ ▸ Nutzdaten  ·  Historie  ·  Zugriffslog                 │
│ kennt den Pass nur als Objekt                            │
└──────────────────────────────────────────────────────────┘
```

---

## 6 — Aufräumen, und der Unterschied wird sichtbar

```bash
E1=$(printf %s "$DID1" | jq -sRr @uri)
E3=$(printf %s "$DID3" | jq -sRr @uri)
TOKEN="$(bundle exec ruby tmp/mint_reo_token.rb 2>/dev/null)"
curl -sS -o /dev/null -w 'Loeschen Pass 1: %{http_code}\n' -X DELETE "$BASE/dpps/$E1" -H "Authorization: Bearer $TOKEN"
curl -sS -o /dev/null -w 'Loeschen Pass 3: %{http_code}\n' -X DELETE "$BASE/dpps/$E3" -H "Authorization: Bearer $TOKEN"
echo "--- und was ist mit den Kennungen? ---"
curl -sS -o /dev/null -w 'DID aus Schritt 1 (Dienst hielt den Schluessel): %{http_code}\n' "https://oydid.ownyourdata.eu/1.0/identifiers/$DID1"
curl -sS -o /dev/null -w 'DID aus Schritt 5 (wir halten den Schluessel):   %{http_code}\n' "https://oydid.ownyourdata.eu/1.0/identifiers/$DID3"
```

Erwartet: beide Pässe `204`. Die vom Dienst geprägte Kennung ist **widerrufen**
(`410`), die eigene löst **weiter auf** (`200`).

> Der Dienst kann nicht widerrufen, wofür er keinen Schlüssel hält. Das ist keine
> Lücke, sondern der Punkt: **die Architektur kann den Ausstieg erzwingen, nicht
> das Vergessen.**

---

## Anhang — Fehlerbilder für Rückfragen

| Situation | Antwort |
|---|---|
| Kennung löst nicht auf | `400` `… does not resolve` |
| `serviceEndpoint` nennt einen anderen Host | `400`, beide Hostnamen im Klartext |
| deklarierte Granularität widerspricht dem Pfad | `400` `granularity 'model' contradicts the identifier path, which expresses 'item'` |
| Kennung länger als 50 Zeichen | `400`, mit Angabe, um wie viel |
| kein oder ungültiges Token | `401 ClientNotAuthorized` |
| fremde DID will schreiben | `403 ClientForbidden` |
| öffentliches Lesen | braucht nie ein Token |

**Was hier bewusst nicht vorkommt:** kein `client_secret`, kein vom Dienst
vergebenes Passwort, keine Registrierung beim Verwahrer, keine Abfrage beim
EU-Register beim Lesen. Alles, was Zugriff gewährt, ist eine vom Inhaber
signierte Aussage mit begrenzter Laufzeit.

**Was heute noch nicht geht:** die abgestuften Leserechte für kontrollierte Daten
(Behörden, Verwerter) sind spezifiziert, aber nicht ausgerollt — die Demo zeigt
die öffentliche Ebene. Und die Bindung des *Inhalts* an die Kennung, mit der auch
der Verwahrer nichts unbemerkt ändern könnte, ist entworfen und noch nicht in
Betrieb; heute ist der **Ort** kryptografisch gebunden, nicht der Inhalt.

---

*Belege zu allen Aussagen: `github.com/OwnYourData/dpp-service-public`,
v3.0.0, `doi:10.5281/zenodo.22117494`, dort `docs/verification/`.*
