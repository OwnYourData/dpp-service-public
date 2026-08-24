# Verification record — carrier identifier and change of custodian

What this directory holds: the record of the run that produced the measurements
the paper reports. Everything here was captured while the run happened, against
the production deployment, and is left as it was written. The individual records
are in German, the language they were taken in.

## What was under test

A passport whose carrier string never changes, moved between two custodians that
are separate at every level that counts for the claim.

| Role | Host | Address |
|---|---|---|
| Economic operator (the printed name) | `dpp.oydapp.eu` | points by DNS at whichever custodian holds the passport |
| Custodian A | `dpp.go-data.at` | 89.58.20.114 |
| Custodian B | `dpp.data-vault.eu` | 152.53.34.232 |

The carrier bears

```
https://dpp.oydapp.eu/01/09520123456791/21/000123
```

49 characters, printed once, unchanged throughout.

Observation was done from outside both clusters — the position a market
surveillance authority would occupy, and therefore the harder evidence.

## The records

| File | What it shows |
|---|---|
| `00-baseline.txt` | starting state, before the operator's name pointed anywhere |
| `01-dns-auf-A.txt` | the operator's name pointed at custodian A |
| `03-controller-trennung.txt` | the two ingress controllers are genuinely separate — the precondition for the switch being the operator's act and not ours |
| `04-verwahrer-a-neu.txt` | custodian A serving the carrier string |
| `05-aufbau.txt` | the full measurement setup, both custodians side by side |
| `06-schritt-a-bis-d.txt` | reading the passport over the carrier without a token, and the lifecycle operations behind it |
| `07-umzug.txt` | **the move.** Certificate before the switch, the switch measured at five-second intervals, and the closing proof that A could no longer have answered |
| `08-serviceendpoint.txt` | the `serviceEndpoint` in the passport's DID document brought to the new custodian — a signed log entry, separate from the DNS change |
| `09-variante-b2.txt` | the second carrier scheme: a self-certifying path, the multihash of a product `did:oyd`, resolving both as a web address and as a DID |
| `09-b2-roh.txt` | raw responses for that scheme |
| `10-did-pruefung.txt` | a passport identifier the operator minted itself, checked at creation: refused when it does not resolve, refused when its `serviceEndpoint` names a different host, accepted when it names the right one |

Raw sampling logs, one line per request, `timestamp dns=… http=… tls=… seconds`:

| File | Window | Points |
|---|---|---|
| `switch-teil1.txt` | 11:55:30Z–12:07:36Z | 131, all served by A |
| `switch.txt` | 12:28:48Z–12:29:11Z | 5, containing the transition |
| `abschluss.txt` | 13:21:27Z–13:23:25Z | 22, during the premature retirement of A, from a location whose resolver still held the old record |

## The three results the paper rests on

**The move is instantaneous and lossless.** 12:29:05Z the carrier string was
answered from 89.58.20.114, 12:29:11Z from 152.53.34.232. No failure, no
certificate error, no change in response time, after 131 prior samples over the
old custodian. What it cost: one delegation naming the new custodian, one write
into its store, one A record in the operator's own zone. No reprint, no new
registration, no changed identifier anywhere downstream.

**Retiring the old custodian is a separate step, and its cost is not
architectural.** Removing the hostname from A produced 404 for 16 of 22 requests
from a location with a stale resolver cache, while a request to B's address
answered 200 at the same moment. The authoritative nameservers had already
switched. The binding constraint is the time-to-live of the operator's A record
— 7200 seconds, and not configurable at the operator's DNS provider. This is why
the custody operation leaves the previous custodian serving by default and
releases it only when explicitly asked.

**A self-minted identifier is checked before it is accepted.** The service holds
no key for a `did:oyd` it did not mint, so it can never correct such a document
afterwards; the only cheap moment is creation. Measured against the running
deployment: an identifier that resolves nowhere is refused, one whose
`serviceEndpoint` names another host is refused with both hostnames in the
answer, and one that names the right host is accepted unchanged. The third case
is what makes the first two mean anything — a check that refused everything
would pass them too.

## Reading the numbers honestly

`switch-teil1.txt` contains one failed sample at 12:07:36Z (`http=000`). The
observer process blocked in name resolution in that second and then stood still
until it was restarted; three control requests immediately afterwards returned
200. It is an artefact of the measurement, not an outage of the measured system.
The loop was given resolution and fetch timeouts afterwards.

In `abschluss.txt`, resolution and fetch are separate operations: the address
noted on a line and the address curl actually used can diverge. The status codes
in that log are meaningful as a proportion of failed requests, not as an
attribution to a particular address. Attribution is done in section 4 of
`07-umzug.txt`, where the address is pinned with `--resolve`.
