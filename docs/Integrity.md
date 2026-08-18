# Identifiers, version chain and integrity

**Status:** describes partly what exists, partly what still has to be closed.
Section 6 names what is **not** implemented today — and the integrity claim we
make in the paper depends on exactly that.

Reference: prEN 18219 (identifiers), prEN 18246 (authenticity and integrity),
prEN 18221 (storage, archiving, persistence).

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
    "serviceEndpoint": "https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fid.lumina.example%2F01%2F09520123456791",
    "payloadHash": "z4Fu…"
  }]
}
```

Two commitments:

1. **`serviceEndpoint`** — where the passport is publicly held. Fixed at
   minting time; changed only through a signed log entry.
2. **`payloadHash`** — the hash of the current passport document in the form in
   which the custodian delivers it.

> **Why the endpoint goes through the `ProductID` and not through the DID:** the
> DID is the hash over exactly that document which would have to contain the
> endpoint. It cannot occur in its own document. The `ProductID` is known at the
> time of minting and is stable.

## 4. Which hash exactly

For a reader to be able to recompute this, it must be unambiguous what is being
hashed. Definition:

- **Subject:** exactly the bytes that the custodian delivers under the
  `serviceEndpoint` with `Content-Type: application/json` — the payload in the
  sense of prEN 18223, without the HTTP frame, without reformatting.
- **Procedure:** `sha256`, multibase-encoded (`z…`), identical to how the DRI is
  formed in the pod, so that pod and DID document carry the same value.
- **No canonicalisation.** Precisely for that reason the custodian stores and
  delivers byte-identically. If it re-serialised, we would need JCS or something
  similar — and a custodian that canonicalises is no longer a
  content-agnostic custodian.

The verification step of a reader is therefore:

```
1. scan data carrier           → {base_url}/p/{short_id}
2. fetch                       → passport document (bytes B)
3. DigitalProductPassportID    → take from B
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
Service           : apply Merge Patch, new bytes B', sha256(B')
Service → Pod     : write B' (the pod archives by itself)
Service           : decrypt document key (KeyVault)
Service → VDR     : log entry with payloadHash = sha256(B'), signed
Service → Client  : 200
```

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

## 6. What is missing today

For the integrity claim to hold in variant B, three things are needed, and
none of them is implemented today:

1. **`payloadHash` in the DID document.** The `serviceEndpoint` is written at
   minting time, a payload commitment does not exist so far.
2. **Returning the expected hash** to the client on every write operation,
   together with a marker that a DID update is outstanding.
3. **Keeping track of the state.** The service has to know and be able to
   display whether the commitment matches the current payload. Proposal: a
   column `did_commit_state` with `committed` / `pending` / `stale`, set on
   writing, resolved by a check against the VDR.

Until 1–3 are in place: **in variant B the integrity is only as good as the
discipline of the client.** The paper must accordingly not claim more.

Open design question on this: should the service **reject** write operations as
long as a previous commitment is outstanding? Availability argues against it —
the client may be offline. In favour argues that otherwise a chain of
uncommitted versions arises in which nobody can say any more which state is the
attested one. My proposal: do not reject, but report `stale` in every read
response, so that the state is visible instead of silent.

## 7. Relationship to the version history in the pod

Two mechanisms that must not be confused:

| | DID log (VDR) | event log of the collection (pod) |
|---|---|---|
| What | signed chain of the DID documents | append-only write log with timestamp and payload hash |
| Who writes | holder, or service with the document key | the pod |
| What for | prEN 18246, integrity **against** the custodian | prEN 18221, state at a point in time; at the same time activity data under Art. 12(c) DGA |
| What it proves | this content was attested by the holder | this content existed at this point in time |

The pod can keep a history without anyone having to believe it — the
attestation is provided by the DID chain. Conversely, the DID chain cannot
serve a point-in-time query. Only both together satisfy 18221 **and** 18246.

## 8. Deletion

`DeleteDPPById` terminates the active passport, not the history (prEN 18221).
In variant A the service revokes the DID with the revocation key; in variant B
only the holder can do this. A revoked identifier is no longer resolvable
afterwards — the archived states in the pod remain retrievable, but their
attestation can only be verified via the previously stored log chain.

> **Known problem:** a soft delete in content-addressed storage must not be
> combined with key-based filtering when reading the history, otherwise the
> version history of a deleted passport becomes unreachable — a silent
> violation of 18221.

## 9. Open items

1. Attribute name for the commitment: `payloadHash` in the service entry, or a
   separate service entry? prEN 18246 makes no stipulation on this.
2. Does `payloadHash` have to be carried along on a pure endpoint change?
   (Yes — otherwise an entry without a payload reference can arise.)
3. Collision behaviour on concurrent updates: the service knows the expected
   predecessor hash and could lock optimistically (`If-Match`).
4. Verification tool for consumers: a minimal verifier that executes steps 1–6
   from section 4 would be the best demonstration of the whole construction.
