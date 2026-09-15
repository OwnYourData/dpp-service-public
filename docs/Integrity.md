# Identifiers, version chain and integrity

**Status:** describes what the service does. Section 6 says how the state of a
commitment is reported, section 9 what is still open.

Reference: EN 18219:2026 (identifiers), prEN 18246 (authenticity and integrity),
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
identifier. That is the basis for prEN 18246 without a distributed ledger.

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
  `serviceEndpoint` with `Content-Type: application/json` — the payload in the
  sense of EN 18223:2026, without the HTTP frame, without reformatting.
- **Procedure:** `sha256`, multibase-encoded (`z…`), identical to how the DRI is
  formed in the pod, so that pod and DID document carry the same value.
- **No canonicalisation.** Precisely for that reason the custodian stores and
  delivers byte-identically. If it re-serialised, we would need JCS or something
  similar — and a custodian that canonicalises is no longer a
  content-agnostic custodian.

The verification step of a reader is therefore:

```
1. scan data carrier           → the uniqueProductIdentifier, an https URL
2. fetch                       → passport document (bytes B)
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
Service → Pod     : read current document
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
Service → Pod     : read, patch, write B'
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
| What for | prEN 18246, integrity **against** the custodian | EN 18221:2026, state at a point in time; at the same time activity data under Art. 12(c) DGA |
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

## 9. Open items

1. The commitment is the `payloadHash` attribute of the `DigitalProductPassport`
   service entry. prEN 18246 makes no stipulation on the name, so it is fixed in
   one place in the code (`DidOyd::PAYLOAD_HASH`) rather than spelled out at
   every call site.
2. Does `payloadHash` have to be carried along on a pure endpoint change?
   (Yes — otherwise an entry without a payload reference can arise.)
3. Collision behaviour on concurrent updates: the service knows the expected
   predecessor hash and could lock optimistically (`If-Match`).
4. `bin/verify_dpp <carrier URL>` executes steps 1–6 for a consumer. It needs
   nothing but the public web — no token, no access to this service — and it
   separates what it checks from what it does not establish: that the signing key
   belongs to the economic operator rather than to a service acting for them
   (EN 18219:2026 6.4.2 b) wants a Verifiable Credential at the operator DID for
   that), and that the trust anchor is an accredited one (prEN 18246 4.8.2 /
   5.2.2 ask for a trusted list; a self-managed DID log is not one). It also
   compares the carrier link with the endpoint the DID document names: different
   hosts are the normal case, because the carrier bears a name the economic
   operator owns and points at the custodian by CNAME, but different *bytes* mean
   a consumer scanning the carrier does not get the attested document.
