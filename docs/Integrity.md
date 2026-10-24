# Identifiers, version chain and integrity

**Status:** describes what the service does. Section 6 says how the state of a
commitment is reported, section 10 how the economic operator signs a passport,
section 11 how every change is bound to the one who asked for it, section 12
what is still open.

Reference: EN 18219:2026 (identifiers), EN 18246:2026 (authenticity and integrity),
EN 18221:2026 (storage, archiving, persistence).

---

## 1. The question that has to explain this

Two statements appear to contradict each other:

- The identifier is the **hash of the DID document**.
- The holder can **change** the DID document, for example to move the storage
  location, without the identifier changing.

Both are true. The contradiction is resolved through the log.

## 2. How `did:oyd` works

When minting, the initial DID document is formed, hashed, and the hash is
multibase-encoded into the identifier:

```
did:oyd:zQmWVzyTPZ19ebpw2Dm9doEDP4qw9rVcs6M4v3iQMo7vpVS
        └─ sha256 over the initial DID document
```

The identifier is therefore **self-certifying**: whoever holds the document can
verify without a registry and without a blockchain that it belongs to this
identifier. That is the basis for EN 18246:2026 without a distributed ledger.

Changes are **not made in the document**, but appended as a signed log entry
that references its predecessor:

```
  Identifier  ──▶  Entry 0 (create)   Document v0   ← hash forms the identifier
                        │ signed with the document key
                        ▼
                   Entry 1 (update)   Document v1
                        │
                        ▼
                   Entry 2 (update)   Document v2   ← current state
                        │
                        ▼
                   Entry n (revoke)   terminated    ← only with the revocation key
```

A resolver starts at the identifier, replays the log and returns the current
document. The identifier stays stable, the document evolves. Whoever verifies
the chain sees every change and its signature — an unnoticed change is not
possible, because every entry is signed with the document key.

**Two keys per DID:**

| Key | Purpose | Loss means |
|---|---|---|
| document key (`documentKey`) | signs updates, signs bearer tokens | no further updates possible |
| revocation key (`revocationKey`) | terminates the DID | the DID persists permanently |

Both are handed out by the registrar **exactly once** and are stored nowhere.

## 3. What the DID document of a passport contains

```json
{
  "service": [{
    "type": "DigitalProductPassport",
    "serviceEndpoint": "https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456795",
    "payloadHash": "z4Fu…"
  }]
}
```

Two commitments:

1. **`serviceEndpoint`** — where the passport is publicly held. Fixed at
   minting time; changed only through a signed log entry.
2. **`payloadHash`** — the hash of the current passport document in the form in
   which the custodian delivers it.

> **Why the endpoint goes through the `uniqueProductIdentifier` and not through the DID:** the
> DID is the hash over exactly that document which would have to contain the
> endpoint. It cannot occur in its own document. The `uniqueProductIdentifier` is known at the
> time of minting and is stable.

## 4. Which hash exactly

For a reader to be able to recompute this, it must be unambiguous what is being
hashed. Definition:

- **Subject:** exactly the bytes that the custodian delivers under the
  `serviceEndpoint` with `Content-Type: application/json`, in the full
  representation of EN 18223:2026 Annex A — the payload in the sense of
  EN 18223:2026, without the HTTP frame, without reformatting. The
  `serviceEndpoint` is an EN 18222:2026 read path, and those answer in the
  compressed representation unless asked otherwise (8.1); a reader fetching it
  therefore adds `representation=full` to the query. The full form is the one
  that is stored, and the only one that carries everything the passport says:
  the compressed form is derived from it and leaves out what a data dictionary
  holds.
- **Procedure:** `sha256`, multibase-encoded (`z…`), identical to how the DRI is
  formed in the pod, so that pod and DID document carry the same value.
- **No canonicalisation.** Precisely for that reason the custodian stores and
  delivers byte-identically. If it re-serialised, we would need JCS or something
  similar — and a custodian that canonicalises is no longer a
  content-agnostic custodian.

The verification step of a reader is therefore:

```
1. scan data carrier           → the uniqueProductIdentifier, an https URL
2. fetch                       → passport document (bytes B), full representation
3. digitalProductPassportId    → take from B
4. resolve DID                 → document v_n
5. sha256(B) == payloadHash?   → integrity
6. signature of entry n        → verify against the document key
```

Steps 5 and 6 together are the claim: the custodian cannot change the passport,
because it does not have the document key.

## 5. Procedure for changes

### Variant A — the service holds the key

```
Client  → Service : PATCH /dpp/v1/dpps/{DID}  (Merge Patch)
Service → Pod     : read current document (public path, no token)
Service           : apply Merge Patch
Service → Pod     : write B' (the pod archives by itself)
Service → Pod     : read B' back from the public serviceEndpoint
Service           : sha256(B') over the bytes as delivered
Service           : decrypt document key (KeyVault)
Service → VDR     : log entry with payloadHash = sha256(B'), signed
Service → Client  : 200 + X-DPP-Payload-Hash, X-DPP-Commit-State: committed
```

The read-back is not a detour. A reader hashes the bytes the custodian hands
them, so those bytes are the only correct subject of the hash -- and the
custodian's byte-identical delivery is re-checked on every write instead of
assumed.


### Variant B — the holder holds the key

```
Client  → Service : PATCH /dpp/v1/dpps/{DID}  (Merge Patch)
Service → Pod     : read (public path, no token), patch, write B'
Service → Client  : 200 + { "payloadHash": "z4Fu…", "didUpdateRequired": true }
Client            : sign the log entry with this hash (locally or CMSM/SE)
Client  → VDR     : publish the entry
```

The difference is decisive: **in variant B the service cannot set the commitment
itself.** It can only request it and keep track of it.

The holder needs a tool of their own for the last two lines, and there are two.
The DPP Manager writes the entry with the passport keys it keeps in its vault,
automatically after every submission and correction, with a button as the
fallback when that fails. `bin/attest_payload` does the same from the command
line for a holder who keeps their keys elsewhere:

```
bundle exec ruby bin/attest_payload <carrier URL | did:oyd:…> --keys <file>
```

It resolves the identifier, fetches the payload back from the endpoint the DID
document names, hashes those bytes and appends the entry — the same procedure as
section 4, run by the party that holds the key. Neither tool goes through this
service, which is the point: a commitment the service could produce would not
prove that the holder made it.

## 6. Reporting the state

Every write asks for a fresh commitment, and every read says which state the
passport is in. The state travels in headers:

```
X-DPP-Payload-Hash: zQme9xtkmy2wFUjDtSAZvGTuxmgbXXi6Ws5LDqf2uyy3S6h
X-DPP-Commit-State: committed
```

| state | meaning |
|---|---|
| `committed` | the DID document commits to the payload as it is delivered now |
| `pending` | the hash is known, the log entry is not written. In variant B that is the normal state until the holder signs, and a read re-checks it; in variant A it means the VDR could not be reached |
| `stale` | the commitment refers to an earlier payload |

**In headers, not in the document.** A reader of the DPP document has to find
exactly the attributes of EN 18223:2026 Table 1 there; a proprietary field would
break conformance for every reader. That is the same reason the storage
configuration arrives in `X-DPP-Storage`. A passport that has never been through
a commitment carries neither header — nothing is asserted about it.

**A passport waiting for the holder is re-checked when it is read.** In variant B
the service holds no document key, so no write of its own could ever turn
`pending` into `committed` — the holder signs the entry, and the service only
gets to look. It does that on its own read paths: resolve the DID, compare the
`payloadHash` in the document with the payload last delivered, and record
`committed` or `stale`. Nothing is written to the VDR, and a check that fails
leaves the state untouched.

Resolving a DID costs a second or two, so a passport is re-checked at most once
per `DPP_COMMIT_RECHECK_INTERVAL` (60 seconds by default), and the timestamp is
recorded even when the check failed — otherwise a DID that no longer resolves
would be the most expensive passport in the database. A `committed` passport is
never re-resolved on a read. The public delivery path is unaffected either way:
it is served by the custodian, not by this service.

**A write is never refused because a commitment is outstanding.** The client may
be offline, and the passport has already been accepted by the custodian; a
failure reported after the fact would be a lie about work that succeeded. What
the service does instead is record the state and show it, so an uncommitted
version is visible rather than silent.

**The commitment is not written on two paths.** After a change of custodian the
`serviceEndpoint` still names the previous one, so a commitment would attest that
custodian's bytes; repointing the endpoint is its own operation. And
`ReadDPPVersionByIdAndDate` serves an archived version, which the commitment is
not about.


## 7. Relationship to the version history in the pod

Two mechanisms that must not be confused:

| | DID log (VDR) | event log of the collection (pod) |
|---|---|---|
| What | signed chain of the DID documents | append-only write log with timestamp and payload hash |
| Who writes | holder, or service with the document key | the pod |
| What for | EN 18246:2026, integrity **against** the custodian | EN 18221:2026, state at a point in time; at the same time activity data under Art. 12(c) DGA |
| What it proves | this content was attested by the holder | this content existed at this point in time |

The pod can keep a history without anyone having to believe it — the
attestation is provided by the DID chain. Conversely, the DID chain cannot
serve a point-in-time query. Only both together satisfy 18221 **and** 18246.

## 8. Deletion

`DeleteDPPById` terminates the active passport, not the history (EN 18221:2026 4.2).
In variant A the service revokes the DID with the revocation key; in variant B
only the holder can do this. A revoked identifier is no longer resolvable
afterwards — the archived states in the pod remain retrievable, but their
attestation can only be verified via the previously stored log chain.

> **Known problem:** a soft delete in content-addressed storage must not be
> combined with key-based filtering when reading the history, otherwise the
> version history of a deleted passport becomes unreachable — a silent
> violation of 18221.

## 9. The controlled part of a passport

A passport with an access policy (AccessClasses.md) is held by a custodian that
supports it as two cards: the public card, which the custodian serves to
everyone, and the controlled card with the attributes that are not public. The
`serviceEndpoint` delivers the public card, so the hash of section 4 is taken
over the public bytes only. A passport with a policy that the service holds
itself is kept the same way, as a public and a controlled part, and its hash
is taken over the public part.

The public card names the controlled one. Among its data elements it carries

```json
{ "elementId": "ControlledData", "objectType": "SingleValuedDataElement",
  "valueDataType": "xsd:string", "value": "zQm…" }
```

whose value is `sha256` over the controlled payload in its JSON
canonicalization (RFC 8785), multibase-encoded like the payload hash. The
controlled payload carries a random value of its own, the data element
`ControlledDataSalt`, which is part of what is hashed.

**What the commitment to the public bytes thereby covers:**

- the controlled part as it was written together with that public card:
  whoever holds the controlled payload recomputes the canonical form, hashes
  it and compares the result with `ControlledData`. The service does so before
  it hands out anything of the controlled part (AccessClasses.md §8); a reader
  with access rights gets the attributes, not the salt;
- that the controlled part changed: every change to it gives the public card a
  new `ControlledData`, and with it a new payload hash and a new log entry.

**What it does not cover:**

- the controlled values themselves for anyone who does not hold them. The
  salt keeps them from being guessed through the hash, even where a value has
  few possibilities;
- the bytes in which the custodian stores and delivers the controlled card.
  The digest is taken over the canonical form, so a custodian that re-orders
  keys does not break it; one that changes a value does;
- which attributes are in the controlled part, or how many;
- earlier versions of the controlled card. Each is covered by the public card
  of its time, through the version history in the pod (section 7).

A write that breaks off between the two cards can leave the public card naming
a controlled payload that is not, or not yet, the one stored. Repeating the
write restores the match.

## 10. The signature of the economic operator

The commitment of section 4 is written with the key of the passport
identifier. It shows that the content is the one that was attested, but not
who attested it: nothing a reader can check links the passport DID to the
economic operator. The passport names the operator in `economicOperatorId`, but
that statement is itself attested with the key of the passport DID. EN 18219:2026
describes economic operator DIDs as the means to sign passports, with the
public key in the DID document, and EN 18246:2026 names the economic operator as
the typical issuer of signed passport data. The economic operator therefore
signs the passport with the key of its own DID, and a reader fetches that
signature next to the passport.

### Form

- A JWS in the compact serialization (RFC 7515).
- Protected header: `alg` is `EdDSA`, `kid` is `<DID>#key-doc`, the document
  key of the economic operator's DID, written as in its bearer tokens (without
  the location suffix of the default repository). `crit` and `b64` are not
  allowed; other members are ignored.
- Payload: the passport as a JSON object, namely its public part in the full
  representation, as a reader without access rights receives it
  (sections 4 and 9). Two payloads are the same if their JSON canonicalization
  (RFC 8785) is the same: unlike the commitment, which hashes bytes, the
  signature covers content, so the order of keys and whitespace do not matter.
- Media type: `application/jose`. The payload is the passport itself, not a
  Verifiable Credential, which `application/vc+jwt` would announce.

### What it covers

Exactly what `payloadHash` covers: the current version of the public part, in
the full representation.

- **The controlled part through `ControlledData`.** The public part names the
  salted digest of the controlled payload (section 9), so the signature binds the
  controlled part the same way the commitment does. The service compares the
  two before it hands out anything of the controlled part (AccessClasses.md §8);
  a reader with access rights cannot recompute the digest, since the salt is
  never handed out.
- **Not the view of a reader with access rights.** Such a reader gets the
  public part with more data elements, and which ones depends on its access
  classes. No signature is delivered with such an answer (see *Delivery*), so a
  verifier never compares a signature with a passport that has more in it than
  was signed. There is no separate signature over the controlled part: its
  attributes fall into several classes, and a signature over all of them would
  hand every class to a reader that may read one.
- **Not the compressed representation.** It is derived from the full one and
  leaves out what a data dictionary holds; it is not signed.
- **Earlier versions keep theirs.** When a write archives a version whose
  signature is `signed`, the version keeps the signature, together with the
  public part it covers. `ReadDPPVersionByIdAndDate` delivers it (see
  *Delivery*).

The signature does not need the commitment: it works for a passport identified
by an `https` URL as well, which has no DID log. Where both exist, they cover the
same content, and each proves something the other does not: the commitment that
the content was not changed since the holder of the passport key attested it,
the signature who stands behind it.

### Signing

Every write changes the public part, at least its `lastUpdated`, and the
signature has to be renewed. The cycle is that of variant B in section 5: after
a write, the economic operator fetches the public part in the full
representation without a token, signs it and submits the signature:

```
PUT /dpp/v1/dpps/{dppId}/signature
Authorization: Bearer <token of the owner>
Content-Type: application/jose

<compact JWS>
```

The service accepts it for a passport it holds itself and checks, in this
order:

1. the JWS is compact, with the header above;
2. the bearer token is the owner's, the DID that created the passport, and
   the DID in `kid` is that same DID;
3. the signature verifies with the document key of that DID as resolved now;
4. the payload is the public part in the full representation as it is
   delivered now.

An accepted signature is answered with `200` and
`X-DPP-Signature-State: signed`. If the DID in `kid` is not the
`economicOperatorId` of the passport, the signature is accepted all the same
and the answer says so in a message of type `Warning`: the signer may be an
authorised representative, which a verifier cannot recognise, and a verifier
reports a signature that is not the economic operator's. A refused signature
leaves the passport as it was: `400 ClientErrorBadRequest` for a malformed JWS,
a signature that does not verify, a payload that is not the passport as
delivered now (a write may have come in between: fetch and sign again), or a
passport held by a custodian; `401` without a valid token; `403
ClientForbidden` if the token or `kid` names another DID than the owner, or
while bearer tokens are not verified (`DPP_AUTH_MODE` other than `did`), since
then there is no owner to compare with.

### State

The state travels in a header, like that of the commitment (section 6), on the
answers of `ReadDPPById` and `ReadDPPByProductId`, of every write, and of the
signature itself. `ReadDPPVersionByIdAndDate` says `signed` where a signature
covers exactly its answer and `none` otherwise:

```
X-DPP-Signature-State: signed
```

| state | meaning |
|---|---|
| `none` | no signature was ever accepted |
| `pending` | the passport was written after the last accepted signature, which is discarded; a new one is expected |
| `signed` | accepted, and at the last check it still verified |
| `stale` | the stored signature no longer verifies: the key of the DID changed, or the DID is revoked or cannot be resolved. It is not delivered |

### Validity

- **Every write discards the signature**, and the passport is `pending`:
  `UpdateDPP`, also one that only names a new access policy, and the
  fine-granular writes. `DeleteDPPById` removes it with the passport.
- **A signature is delivered only if its payload is the public part as it
  stands.** This is compared on every delivery and costs no network, so a
  signature that no longer matches the passport is never handed out, whichever
  path changed it.
- **The key is checked again on reads**, at most once per
  `DPP_SIGNATURE_RECHECK_INTERVAL` (300 seconds by default, as long as a
  resolved key is cached). A signature that no longer verifies, or whose DID
  cannot be resolved, is `stale`; once it verifies again it is `signed` again.
  A signature is never delivered on the assumption that it still holds.

### Delivery

`ReadDPPById` and `ReadDPPByProductId` answer with the JWS
(`Content-Type: application/jose`) when the request prefers `application/jose`
over `application/json` in its `Accept` header, the state is `signed`, and the
payload is exactly the JSON the same request would get otherwise. In practice
that means:

- the request asks for `representation=full`, since the compressed
  representation is not signed;
- the reader gets the public part, with no access class applied. A reader with
  access rights who wants the signature fetches it without a token.

Otherwise the answer is the JSON one, as without the `Accept` header, with
`X-DPP-Signature-State`. A verifier that compares the signature with the JSON
answer to the same request therefore never finds a mismatch, whoever asks and
in which representation. Every answer of these paths varies with `Accept`.

`ReadDPPVersionByIdAndDate` answers the same way with the signature kept for
the version it reads: with `application/jose` and `representation=full`, the
JWS if its payload is exactly the JSON the same request gets, and that JSON
otherwise. A reader without access rights gets the public part kept with the
version as long as the passport's access policy is the one the version had
(AccessClasses.md §9); under another policy the version is filtered by
today's, its public part can read differently from what was signed, and no
signature is delivered for it. Which key signed is not checked again for an
earlier version: a later change of the key does not undo a signature that held
when it was given. `bin/verify_dpp` reads every version the DID log records
and checks its signature.

Only passports this service keeps in its own database carry a signature here.
A passport held by a custodian is read at the custodian, over the carrier and
the `serviceEndpoint`, and the service accepts no signature for it.

## 11. Every change bound to its author

The commitment shows that the content is the attested one, the signature of
section 10 who stands behind the public part of a version. Neither shows who
asked for a change: the service makes it, and in variant A it also writes the
log entry. EN 18246:2026 expects every change to be bound to the identity that
made it, in a form that identity cannot later deny. Two things do that here,
for every request that changes something: the writes of a passport
(`CreateDPP`, `UpdateDPPById`, the fine-granular writes, `DeleteDPPById`, the
change of custodian, the renewal of the mandate, the signature), and the
registration of access policies and of access grants and their revocation.

### The token names its request

The self-issued bearer token of a write carries the claim `rqh`:

```
rqh = base64url( SHA-256( METHOD "\n" TARGET "\n" base64url( SHA-256( BODY ) ) ) )
```

- `METHOD` is the request method in capitals.
- `TARGET` is the request-target exactly as in the request line: the path with
  the query where there is one, percent-encoding untouched (RFC 9112 3.2.1).
  Scheme and host are not part of it; `aud` already names the service.
- `BODY` is the bytes of the request body as sent, with no canonicalisation;
  an empty body is the empty octet string.
- base64url is without padding, as `ath` is in DPoP (RFC 9449).

The token is signed with the document key of the issuer's DID, names this
service as `aud`, lives at most 15 minutes and is accepted once (`jti`). With
`rqh` it is the issuer's signed statement that it asked for exactly this
request. The service compares the claim with the request before anything
happens. A claim that names another method, target or body is refused with
`401` and `WWW-Authenticate: Bearer error="invalid_token"`.

A write whose token has no `rqh` is accepted until the day set in
`DPP_REQUEST_BINDING_FROM`, with the header

```
X-DPP-Request-Binding: missing;until="2026-12-01"
```

and is refused like a token that does not hold from that day on. Reads need no
`rqh`. Without verified tokens (`DPP_AUTH_MODE` other than `did`) nothing is
bound.

### The write log

Every write has two entries in the write log, which entries are only ever
added to (in PostgreSQL a trigger refuses to change or delete them):

| Entry | When | What |
|---|---|---|
| `request` | after the token is verified and bound, **before** anything changes | time, request id, operation, the passport the path names, issuer, `jti`, the token, `rqh`, whether it was bound, method, request-target, digest of the body |
| `outcome` | when the request ends | request id, HTTP status, the passport (for `CreateDPP` known only now), the version the write produced; for `DeleteDPPById` the archived final version |

If the `request` entry cannot be written, the write is refused with `500` and
nothing changes: there is no change without its evidence. The token is kept as
it was presented; with its first use it is spent, and it is valid at no other
service. Nothing of the body or of the passport is kept: the body is bound by
its digest, the content of each version is the archived version.

The log is not handed out over the API. The operator exports the entries of a
passport for its owner, and the owner checks them with nothing but the file
and the public web:

```
bin/rails dpp:writes:export DPP=<passport identifier> > writes.jsonl
bundle exec ruby bin/verify_writes writes.jsonl
```

`bin/verify_writes` checks for every write that the token verifies with the
key of its issuer, that it names the issuer, `jti` and `rqh` the entry records,
that `rqh` is the hash of the method, target and body digest recorded, and
that the write lies within the lifetime of its token. Across the writes it
checks that no `jti` comes twice, that every write has an outcome, and that no
version is without a write. Unbound writes are listed as such. Whoever keeps
the bodies they sent can compare their digests as well.

Entries are kept for `DPP_WRITE_LOG_RETENTION_DAYS` (ten years by default),
and those of a passport for as long as the passport or one of its archived
versions exists. `bin/rails dpp:writes:prune` removes only older entries that
name no passport, or a passport of which nothing is left.

### What this establishes

A bound entry shows that the holder of the issuer's key asked for this
request, with this body, at this time. With the archived version the request
produced and the signature of the economic operator over its public part
(section 10), every change of a passport this service keeps is bound to the
one who asked for it, and every signed version to the one who stands behind
it. Writes on passports held by a custodian are bound and logged the same way;
their versions are kept by the custodian.

The log is kept by the service. A removed entry shows as a version without a
write, a log rewritten as a whole cannot be told apart from inside it; the DID
log and the signatures of the economic operator are the records outside the
service's database.

## 12. Open items

1. The commitment is the `payloadHash` attribute of the `DigitalProductPassport`
   service entry. EN 18246:2026 makes no stipulation on the name, so it is fixed in
   one place in the code (`DidOyd::PAYLOAD_HASH`) rather than spelled out at
   every call site.
2. Does `payloadHash` have to be carried along on a pure endpoint change?
   (Yes — otherwise an entry without a payload reference can arise.)
3. Collision behaviour on concurrent updates: the service knows the expected
   predecessor hash and could lock optimistically (`If-Match`).
4. `bin/verify_dpp <carrier URL>` executes steps 1–6 for a consumer, checks
   the signature of the economic operator (section 10), and reads every
   version the DID log records with its signature. It needs nothing but the
   public web — no token, no access to this service — and it separates what it
   checks from what it does not establish: that the DID which signed belongs to
   the company it stands for (EN 18219:2026 6.4.2 b) wants a Verifiable
   Credential at the operator DID for that), and that the trust anchor is an
   accredited one (EN 18246:2026 expects an accredited trust anchor; a
   self-managed DID log is not one). It also
   compares the carrier link with the endpoint the DID document names: different
   hosts are the normal case, because the carrier bears a name the economic
   operator owns and points at the custodian by CNAME, but different *bytes* mean
   a consumer scanning the carrier does not get the attested document.
