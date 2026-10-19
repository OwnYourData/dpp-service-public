# Access classes

**Status:** describes the vocabulary, the access policy, how a policy is
attached to a passport, how a passport with a policy is held as a public and a
controlled part, who may read the controlled part (access grants), what
each reader gets on the read paths, and how every access is logged.

Reference: prEN 18239 (access rights management, information system security and
business confidentiality, logging of access to restricted data, 5.2);
Regulation (EU) 2022/868 (Data Governance Act), Article 12; Regulation (EU) 2023/1542 (batteries), Article 77(2)
and Annex XIII; EN 18223:2026 (semantic model).

---

## 1. Why a vocabulary

prEN 18239 asks for access rights at the level of individual properties, defined
through controlled vocabularies, because the roles that read a passport change
over time while the classification of a property should not. The vocabulary
below names the classes; which role may read which class is decided elsewhere.

## 2. The classes

Scheme: `https://w3id.org/soya/dpp-access/v1` (SKOS, file
[`config/vocab/dpp-access-v1.jsonld`](../config/vocab/dpp-access-v1.jsonld)).

| Notation | IRI | Level | Who may read |
|---|---|---|---|
| `public` | `https://w3id.org/soya/dpp-access/v1#public` | 0 | anyone, without authentication |
| `legitimateInterest` | `https://w3id.org/soya/dpp-access/v1#legitimateInterest` | 1 | actors with a legitimate interest in the attribute (for instance repair, refurbishment, recycling) and authorities |
| `authority` | `https://w3id.org/soya/dpp-access/v1#authority` | 2 | authorities only: notified bodies, market surveillance and customs authorities, the European Commission |

The classes are ordered by level: whoever may read a class may read every class
with a lower level. They correspond to the three access groups the Battery
Regulation distinguishes for the battery passport — the general public, persons
with a legitimate interest, and notified bodies, market surveillance authorities
and the Commission.

The classes are not roles. A role such as "recycler" is granted one or more
classes; that mapping is not part of the vocabulary.

## 3. The access policy

An access policy assigns a class to the data elements of a passport. It is a
document of its own, written per product type, and is never part of the
passport: nothing of it appears in the header attributes of EN 18223:2026
Table 1 or in the data elements. Format:
[`config/vocab/access-policy.schema.json`](../config/vocab/access-policy.schema.json).

```json
{
  "id": "https://dpp.example.org/access-policies/led-lamp/1",
  "scheme": "https://w3id.org/soya/dpp-access/v1",
  "rules": [
    { "path": "SubstancesOfConcern", "accessClass": "public" },
    { "path": "SubstancesOfConcern/MaterialComposition", "accessClass": "legitimateInterest" }
  ]
}
```

- `path` names a data element by its element identifiers from the top level
  down, separated by `/` — the same path `UpdateDataElement` takes.
- `accessClass` is a notation or an IRI from the scheme.
- `default` (optional) is the class of an attribute no rule reaches.

How a passport is classified (`AccessPolicy#classify`):

1. The header attributes of EN 18223:2026 Table 1 are always `public`. A rule on
   one of them is refused.
2. A data element takes the class of the deepest rule on itself or on a
   collection above it; a rule on a collection covers everything below it that
   no deeper rule reaches.
3. The attributes are the header attributes and every data element that is not
   a collection. The items of a multi-valued or multi-language element belong
   to that element and share its class.
4. An attribute no rule reaches gets the policy's `default`, or `authority` if
   the policy names none. A value published by mistake cannot be withdrawn; a
   value withheld by mistake can be released.

Every attribute ends up with exactly one class. The result also lists the
attributes that fell to the default and the rules that reached nothing, so that
a gap in a policy is visible rather than silent.

## 4. Examples

Two policies are kept with the specs (`spec/fixtures/access-policies/`):

- **LED lamp** (the passport of [examples-lightbulb.md](examples-lightbulb.md)):
  everything `public` except the material composition, which is
  `legitimateInterest`.
- **Battery**: identification, category, mass, warranty, carbon footprint,
  hazardous substances and the declaration of conformity are `public`; the date
  of putting into service, the status, the detailed composition, dismantling
  information and performance data are `legitimateInterest`; the results of
  test reports are `authority`. The attribute names are illustrative.

## 5. Attaching a policy to a passport

An economic operator registers the policy of a product type once and names it
by its `id` in each passport of that type. Only the `id` travels with a passport:
a policy for a product type with many attributes does not fit into a request
header.

**Registering.** `PUT /dpp/v1/access-policies` with the policy as the body and
the operator's bearer token:

| Answer | Meaning |
|---|---|
| `201` | registered |
| `200` | the same policy was registered under this `id` before (members and rules may be in another order) |
| `409` | a different policy is registered under this `id` |
| `400` | not a valid policy |

A registered policy never changes. The classification of a passport has to stay
traceable to the policy it was made under, so a new version of a policy is
registered under a new `id`, for instance `…/led-lamp/2`. The `id` is an
absolute URI in printable ASCII of at most 512 characters. A policy belongs to
the operator that registered it; another operator using the same `id` has a
policy of its own.

**Naming it in a passport.** `CreateDPP` takes the header

```http
X-DPP-Access-Policy: https://dpp.example.org/access-policies/led-lamp/1
```

The request is refused with `400 ClientErrorBadRequest` before a DID is minted or
a custodian is asked if the header is empty, if the operator has registered no
policy under that `id`, or if the policy cannot classify the passport (a data
element without an `elementId`). Without the header a passport is created as
before, with no policy.

`UpdateDPP` takes the same header and replaces the passport's policy; with the
merge patch `{}` it changes nothing else. A policy cannot be removed from a
passport. The fine-granular write paths leave the policy as it is and refuse the
header. A change of custodian keeps the policy: it is held by this service, not
by the custodian.

**Warnings.** Every write of the owner on a passport with a policy (`CreateDPP`,
`UpdateDPP`, `UpdateDataElement`, a collection patch) answers with the policy
and two counts for the passport as it now stands, as an RFC 8941 item:

```http
X-DPP-Access-Policy: "https://dpp.example.org/access-policies/led-lamp/1";unclassified=1;unused-rules=1
```

- `unclassified`: attributes no rule reaches; they take the policy's default.
- `unused-rules`: rules that reach no attribute of the passport.

The attributes and rules themselves are listed, for the owner only, by
`GET /dpp/v1/dpps/{id}/access-policy`:

```json
{
  "policy": "https://dpp.example.org/access-policies/led-lamp/1",
  "unclassified": ["Manufacturer"],
  "unusedRules": ["Recycling"]
}
```

The read paths and the discovery document do not carry the header.

## 6. The public and the controlled part

A custodian that supports it holds a passport with a policy as two cards in the
same collection, with the same `digitalProductPassportId` and
`uniqueProductIdentifier`, written under the same write delegation:

| Card | Holds | Served |
|---|---|---|
| `DigitalProductPassport` | the header and the `public` attributes | on the custodian's public paths, to anyone |
| `DigitalProductPassportControlled` | the header and every other attribute, `legitimateInterest` and `authority` alike | not on the public paths |

A collection whose data elements fall on both sides appears on both cards, each
time with its own metadata and its own elements. The public card names the
controlled one in a data element `ControlledData`, a salted hash over the
controlled payload; Integrity.md §9 says what that hash binds.

A reader without access rights gets the public card, as at the custodian
itself. The controlled card goes only to readers with access rights (section
8); the service reads it under its own read grant as protected reader of the
collection. A write answers the owner with the whole passport.

**Writing.** Every write of such a passport writes the controlled card first,
then the public card. When a new policy moves attributes from the controlled to
the public part, the controlled card is written a second time, after the public
card, so that a write that breaks off at any point loses no value and
publishes none early; sending the same request again completes it. A policy
that leaves nothing controlled leaves the controlled card in place, with no
attributes.

**Earlier versions.** The custodian keeps every version of the public card.
When a stricter policy moves an attribute into the controlled part, the
versions of the public card written before keep its value.

**Custodians that do not hold controlled cards.** A passport whose policy
leaves attributes that are not public is refused with `400
ClientErrorBadRequest` on such a custodian: at `CreateDPP`, at `UpdateDPP` and
the fine-granular writes, and at a change of custodian to it. The custodian
would publish those attributes, and a published value cannot be called back.
A policy that leaves every attribute public is accepted there, and the
passport is held as one card.

**Collections without the service's reader.** At a custodian that holds
controlled cards, the same writes first ask whether the custodian has entered
this service as protected reader of the target collection (Delegation.md §3):
the service requests a token under its read grant for that collection, and the
custodian answers `invalid_grant` if the reader is not entered. Without the
reader no one could read the controlled card through this service, so such a
passport is refused with `400 ClientErrorBadRequest` before anything is
written, minted or moved. The message carries the code `readerNotEntered`,
names the custodian, the collection and the reader DID, and asks the economic
operator to have the custodian enter it.
A passport whose policy leaves every attribute public is not checked.

The answer is kept for a while in each instance of the service: an entered
reader for 15 minutes, a missing one for one minute, so a reader entered
meanwhile is seen soon. A custodian that cannot be asked leaves the question
open: the write is refused with `502 ServerErrorBadGateway`, and the next
write asks again. Neither grant nor token is logged. How a passport already
held at such a collection is read is in §8.

**A change of custodian** takes the controlled card along. It is read under
the delegation for the current custodian; if that has expired, the change is
refused until the delegation is renewed. `release_previous` releases both
cards at the previous custodian.

**Passports this service holds itself** (without `X-DPP-Storage`) are held
the same way when they have a policy: the public part, naming the controlled
one in `ControlledData`, and the controlled part with its salt. The payload
hash of such a passport (Integrity.md) is taken over its public part, which is
what a reader without access rights gets.

## 7. Access grants

An access grant says that a reader, named by its DID, may read the controlled
part of certain passports in certain classes. It is a statement signed by its
issuer:

```
header  { "alg": "EdDSA", "typ": "dpp-access-grant+jwt", "kid": "<iss>#key-doc" }
claims  { "iss": "<issuer DID>",
          "sub": "<reader DID>",
          "aud": "<DID of this service>",
          "roles": ["legitimateInterest"],
          "dpps": ["<passport identifier>", …],
          "purpose": "repair",
          "iat": …, "nbf": …, "exp": …, "jti": "<name of the grant>" }
```

- `roles` names access classes of the vocabulary (notation or IRI), not
  `public`. Whoever holds a class reads every class below it.
- `dpps` names the passports the grant covers. Instead of `dpps`, `"scope":
  "issuer"` covers every passport of the issuer.
- `purpose` is optional and only informative.
- The service's DID for `aud` is published under `/.well-known/dpp-service`.
- A grant lasts at most 365 days and ends at its `exp`.

**Who may grant what.**

| Class | Granted by | Covers |
|---|---|---|
| `legitimateInterest` | the economic operator, with the DID that owns the passports | only its own passports |
| `authority` | an issuer on the list of authority issuers | with `scope` `issuer`, every passport the service holds |

Whether a DID belongs to a market surveillance authority, a customs authority,
a notified body or the Commission is not something the economic operator
decides, nor something the service can tell from the DID. The service takes
the word of the issuers on its list. The list is part of the service's
configuration (`DPP_AUTHORITY_ISSUERS`) and is published under
`/.well-known/dpp-service` as `authorityIssuers`. A grant for `authority` gives
that class only while its issuer is on the list.

**Registering.** The issuer registers a grant once, with
`PUT /dpp/v1/access-grants`, the grant as the body (`Content-Type:
application/jwt`) and its own bearer token:

| Answer | Meaning |
|---|---|
| `201` | registered |
| `200` | this grant was registered before |
| `400` | not a valid grant |
| `403` | the token is not the issuer's, or the issuer may not grant this: `authority` from an issuer not on the list, or passports of another owner |
| `409` | a different grant of this issuer is registered under the same `jti` |

`GET /dpp/v1/access-grants` lists the grants the presenting DID has issued, with
their claims, but not the signed statements.

**Revoking.** The issuer revokes a grant with
`DELETE /dpp/v1/access-grants/{jti}` and its own bearer token:

| Answer | Meaning |
|---|---|
| `200` | revoked, now or before; the answer says when (`revokedAt`) and by whom (`revokedBy`) |
| `404` | the presenting DID has issued no grant under this `jti` |

A revocation takes effect at once. Which classes a reader holds is worked out
from the registered grants on every read; nothing of it is kept in between, and
an answer with access rights is never stored by a cache. A revoked grant stays
revoked: registering the same grant again answers `200` with `revoked: true`.

Only the issuer revokes over the API. An economic operator cannot revoke a
grant it did not issue, an `authority` grant above all. The operator of the
service can revoke any grant on order, with a reason, in its own environment
(§10); the issuer sees that in its access log. An authority issuer as a whole
is removed by taking it off the list of authority issuers.

## 8. Reading

Every read path — `ReadDPPById`, `ReadDPPByProductId`,
`ReadDPPVersionByIdAndDate`, `ReadDataElement` and the collection path — gives
each reader the attributes of the classes it may read, and nothing else:

| Reader | Gets |
|---|---|
| without a bearer token | the public part |
| with a token, without a grant for the passport | the public part |
| with a grant for `legitimateInterest` | the public part and the `legitimateInterest` attributes |
| with a grant for `authority` | the whole passport |
| the economic operator that owns the passport | the whole passport |

A reader presents the same self-issued bearer token as a writer: signed with
the document key of its DID, with this service as `aud`, for at most 15
minutes. The grant itself is not presented; the service finds it by the
reader's DID. A token that is presented but does not hold is answered with
`401`, not read past. Without verified tokens (`DPP_AUTH_MODE` other than
`did`) every reader gets the public part.

The answer is the passport of EN 18223:2026 with more data elements, nothing
else. The header attributes are those of the public part; `ControlledData`
stays as the public part has it; `ControlledDataSalt` is never handed out. An
attribute a reader may not read is absent, and the fine-granular paths answer
`404` for it, as for one that does not exist. Response headers, never the
passport, say what was applied:

```http
X-DPP-Access-Roles: legitimateInterest
Cache-Control: private, no-store
Vary: Authorization
```

`X-DPP-Access-Roles` names the classes beyond `public` that were applied.
Every answer of a read path varies with `Authorization`; one with access rights
is not stored by any cache.

**When the controlled part cannot be read.** If the custodian does not accept
this service as reader of the passport's collection — its token endpoint
answers the read grant with `invalid_grant` — a reader with access rights gets
what a reader without them gets: the public part, with `200`. The answer says
so in a header, as an RFC 8941 item with the reason:

```http
X-DPP-Controlled-Part: unavailable;reason=readerNotEntered
Cache-Control: private, no-store
```

It carries no `X-DPP-Access-Roles`, since no class beyond `public` was
applied. On the fine-granular paths an attribute of the controlled part is
answered with `404` and the same header, and the message says that the
controlled part of the passport is unavailable. Nothing is read at the
custodian; the access log records the read with the reason (§10), and the
service's log names the custodian and the collection. The economic operator
settles it with the custodian, who enters the reader. Any other failure at
the custodian — no answer, or a refusal other than `invalid_grant` — is
answered with `502 ServerErrorBadGateway`.

Every read with access rights is logged, and so is every read by a reader with
a valid token but without a valid grant for a passport that has a policy
(§10). A reader without a token is not logged: it reads what is public.

**Integrity.** Before anything of the controlled part is handed out, its
digest is compared with `ControlledData` of the public part (Integrity.md §9).
If they do not match, the service reads both once more, since a write may be
under way. If they still do not match, the answer is `502
ServerErrorBadGateway`, and nothing of the controlled part is handed out.
Readers without access rights are not affected.

## 9. Earlier versions

`ReadDPPVersionByIdAndDate` gives each reader the same classes as for the
current passport. A version is filtered by the passport's access policy as it
is today, also for readers without access rights: an attribute that is
controlled today is not handed out from a version in which it was still
public.

- **At a custodian**, the public card as it stood at that time comes from the
  custodian's public path. For a reader with access rights the service adds the
  version of the controlled card whose digest that public card names, read
  under its read grant. A custodian that does not serve versions of controlled
  cards leaves the reader with the public part of the version, and the answer
  says so: `X-DPP-Controlled-Part: unavailable;reason=versionsNotServed`.
  `X-DPP-Access-Roles` is only sent if the reader's classes let through more
  of that public part than a reader without access rights gets: an attribute
  that is controlled today but was public in that version. A custodian that
  does not accept this service as reader is answered as in §8.
- **In the service's own database**, every version holds the whole passport,
  together with its policy and owner, so it stays readable per role after the
  passport has been deleted.

The custodian's own public path for earlier versions is not filtered by the
service: versions of a public card written before an attribute became
controlled keep its value there.

## 10. Access log

The service logs who read what of the controlled part of a passport. One
entry per event:

| Event | When |
|---|---|
| `read` | a reader with access rights read a passport |
| `integrityError` | the same, but the controlled part did not match its digest, and nothing of it was handed out (`502`) |
| `refused` | a reader with a valid token and no valid grant read a passport that has a policy |
| `serviceRead` | the service read at a custodian under its own read grant without a reader causing it (see below) |
| `grantRegistered` | an access grant was registered |
| `grantRevoked` | an access grant was revoked, by its issuer or the operator |

An entry of a read names the time, the passport and its owner, the reader's
DID, the classes applied and whether the reader is the owner or holds grants
(`basis`), the grants as issuer and `jti`, the operation, the date of
`ReadDPPVersionByIdAndDate`, the HTTP status of the answer, the request id,
and, at a custodian, the object read there and the `ControlledData` of the
version handed out. A refusal says why: `noGrant`, or the grant concerned and
`revoked`, `expired`, `notYetValid` or `issuerNotListed`. A read whose
controlled part could not be read because the custodian does not accept this
service as reader (§8) is a `read` with no classes applied and the reason
`readerNotEntered`; an earlier version whose controlled card the custodian
does not serve (§9) is a `read` with the reason `versionsNotServed`. The log
never holds content, tokens or signed statements.

An answer that hands out the controlled part is only sent once its entry is
written; if it cannot be written, the answer is `500` and nothing of the
controlled part leaves.

**Reads at the custodian.** The custodian keeps its own trail of what this
service read there under its read grant. The access log has exactly one entry
for each such read: the read that delivered the controlled part to a reader is
part of that reader's entry, every other one is a `serviceRead` with its
reason:

| Reason | Read |
|---|---|
| `lookup` | finding the controlled card of a passport: object list, index card, meta |
| `retry` | reading the controlled card again before a mismatch with the digest is final |
| `version` | searching the version of a controlled card a public version names |
| `measure` | the operator's measurement |
| `internal` | anything else |

The two line up by object and time: each entry of the custodian's trail has
one entry here, which says which reader it was for, or why there was none.

**Who sees what.** `GET /dpp/v1/access-log`, with a bearer token, gives the
entries that concern the presenting DID, newest first:

| As | Sees |
|---|---|
| owner of passports | every entry of its passports, `serviceRead` included |
| reader | its own reads and refusals |
| issuer of grants | its grants registered and revoked, and the reads made under them |

Filters: `dppId`, `event`, `since`, `until`. Pages of `limit` entries (100 by
default, at most 1000); the answer's `next` is passed as `after` for the next
page. The log is only served while tokens are verified.

The operator of the service sees the whole log and acts on it in its own
environment, not over the API:

```
bin/rails dpp:access:log [DPP=…] [EVENT=…] [SINCE=…] [UNTIL=…] [DID=…] [LIMIT=…]
bin/rails dpp:access:revoke ISSUER=<issuer DID> JTI=<jti> REASON="<order>"
bin/rails dpp:access:prune
```

**Keeping.** Entries are only ever added. Nothing in the service changes or
deletes them, and in PostgreSQL the database itself refuses to. They are kept
for five years (`DPP_ACCESS_LOG_RETENTION_DAYS`, in days); only the
operator's `dpp:access:prune` removes older ones.

## 11. Scope

Passports without a policy are held and delivered as before, in full, to every
reader, and reads of them are not logged. The access log protects against
changes by the service, not against someone who can change its database
directly.
