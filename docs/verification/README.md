# Verification record — carrier identifier, data model, and change of custodian

What this directory holds: the record of the run that produced the measurements
the paper reports. Everything here was captured while the run happened, against
the production deployment, from outside both custodians' clusters — the position
a market surveillance authority would occupy, and therefore the harder evidence.

The run of 2026-08-25 was made against the **published** editions of the JTC 24
standards. The attribute names, the element model and the method names below are
those of EN 18222:2026 and EN 18223:2026, not of the 2025 drafts.

## What was under test

A passport whose carrier string never changes, moved between two custodians that
are separate at every level that counts for the claim.

| Role | Host | Address |
|---|---|---|
| Economic operator (the printed name) | `dpp.oydapp.eu` | points by DNS at whichever custodian holds the passport |
| Custodian A | `dpp.go-data.at` | 89.58.20.114 |
| Custodian B | `dpp.data-vault.eu` | 152.53.34.232 |
| DPP service | `dpp-service.ownyourdata.eu` | image 260825b |

The carrier bears

```
https://dpp.oydapp.eu/01/09520123456791/21/000123
```

49 characters, printed once, unchanged throughout.

## The records

| File | What it shows |
|---|---|
| `00-ingress-separation.txt` | the precondition, measured 2026-08-22: the two ingress controllers are genuinely separate, so what decides which custodian answers is the A record in the operator's zone and not a rule of ours |
| `01-carrier-and-model.txt` | reading the passport over the carrier without a token, and the published data model: EN 18223:2026 Table 1 attribute names, the uniform `elements` tree of Annex A, granularity checked against the path, fine-granular element access |
| `02-order-of-the-two-acts.txt` | **the move in the wrong order.** DNS first, custody second — the refusal that produces over the printed carrier, and what a single refusal can and cannot establish |
| `03-the-correct-order.txt` | **the move in the correct order.** Custody first, DNS second, release last: 41 samples across the change, no deviation; and two public resolvers giving different answers one minute after the change, both of which work |
| `04-identifier-check.txt` | a passport identifier the operator minted itself, checked at creation: refused when it does not resolve, refused when its `serviceEndpoint` names a different host, accepted when it names the right one |
| `05-serviceendpoint-and-did-core.txt` | where the DID document sends a reader, what the resolver says about the relation between an issued and a current identifier, and one deviation reported to the method maintainers |
| `06-carrier-scheme-b2.txt` | the second carrier scheme: a self-certifying path, the multihash of a product `did:oyd`, resolving both as a web address and as a DID — 50 characters, the registry's limit, and what that limit costs in collision resistance |

Raw sampling logs, one line per request:

| File | Window | Points |
|---|---|---|
| `90-sampling-wrong-order.txt` | 17:03:44Z–17:19:39Z | 173, `timestamp dns=… http=… tls seconds`; exactly one 404 |
| `91-sampling-correct-order.txt` | 18:09:23Z–18:11:42Z | 41, taken on the operator's own machine with both custodian addresses pinned by `curl --resolve`; no deviation |

## The results the paper rests on

**The carrier is read in one request.** No token, no resolver, no redirect: the
printed string is an address, and the answer is the passport in the attribute
names of EN 18223:2026. The identifier the standard calls
`uniqueProductIdentifier` is both the identity and the web link, so there is no
second carrier token — and no proprietary attribute beside it, which would break
conformance for every reader.

**A change of custodian costs a delegation, a log entry and a DNS record.** It
costs nothing that was printed, nothing that was registered, and no identifier
anywhere. Measured in both directions on the same passport, with the two acts in
each order.

**The order of the two acts is not a matter of taste, and the overlap is not a
convenience.** DNS answers stay in circulation for the zone's time-to-live —
7200 s here, and not configurable at this operator's DNS provider. One minute
after the record changed, two independent public resolvers still gave different
answers; both worked only because both custodians were serving. Custody
therefore moves first, the DNS record second, and the previous custodian is
released after the time-to-live, not with the move.

**The carrier does not have to be a GS1 Digital Link.** EN 18219:2026 5.3 admits
an identification link under a domain the operator owns, and the same service
serves both. Measured with a path that is the multihash of a product `did:oyd`:
50 characters — the registry's upper limit — self-certifying, readable both as a
web address and as a DID. What it costs is stated with it: granularity can only
be declared rather than derived, the scan no longer yields GTIN and serial, and
the length limit caps the digest at 144 bits.

**A self-minted identifier is checked before it is accepted.** The service holds
no key for a `did:oyd` it did not mint, so it can never correct such a document
afterwards; the only cheap moment is creation. An identifier that resolves
nowhere is refused, one whose `serviceEndpoint` names another host is refused
with both hostnames in the answer, and one that names the right host is accepted
unchanged. The third case is what makes the first two mean anything — a check
that refused everything would pass them too.

## Reading the numbers honestly

**Where a measurement was taken decides what it can claim.** Two observation
points were used in this run: a remote host, and the operator's own machine. The
remote host sits behind an egress proxy that resolves names itself and silently
ignores `curl --resolve` — pinned to 203.0.113.99, an address reserved for
documentation where nothing is listening, it still returned 200. Every
address-level attribution in these records therefore comes from the operator's
machine, where that same counter-check fails as it should. The remote host is
used only where the hostname itself is the subject, never to establish which of
two addresses answered. An earlier draft of record 2 did make such an
attribution; it has been removed rather than quietly corrected.

The single 404 in `90-sampling-wrong-order.txt` establishes that a gap existed,
and nothing about its size. That log cannot say which custodian answered any
individual sample, for the reason above. A client whose cache already held the
new address would have been refused on every request in those 71 seconds.

`91-sampling-correct-order.txt` deliberately does not wait for DNS to converge.
With a 7200-second lifetime that would take hours and would say nothing the zone
file does not already say. Both custodian addresses are pinned with
`curl --resolve` instead, so the claim under test is the one that matters to a
reader: at every moment of the transition, both addresses answer, and therefore
no cache state can produce a failure.

Deviations from the standards are declared in the records rather than omitted:
the element path is a path of element identifiers instead of the RFC 9535
JSONPath EN 18222:2026 asks for in `elementIdPath`, and the collection endpoints
are an addition to the method set rather than part of it.
