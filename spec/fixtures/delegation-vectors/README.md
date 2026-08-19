# Delegation conformance vectors

Fixture set for the delegation model in `docs/Delegation.md`. Eleven requests
against the token endpoint: one that has to succeed, ten that have to be
refused, each with the error code `Delegation.md` §14 prescribes.

The point of these files is that the pod and the DPP Service can be built
**independently**. The pod runs them as a test fixture without a DPP Service
existing; the DPP Service checks that its own signing code reproduces
`01-valid` byte for byte. Where the two sides would otherwise drift — a claim
named `collection` on one side and `collection_id` on the other — the fixtures
fail immediately instead of at the first joint end-to-end run.

## Format

Every file is one JSON object:

| Field | Meaning |
|---|---|
| `id`, `description`, `checks` | what this vector is for, and which rule it exercises |
| `now` | **freeze the clock to this value.** All `iat`/`exp` are absolute; without a frozen clock the set expires |
| `resolver` | DID → DID document. Stub your resolver with this map; the vectors do no network I/O |
| `collection` | the collection's state: `id`, `controller_did`, `allowed_act` |
| `preconditions` | vector ids that must have been run before this one (only `05-jti-replay` uses it) |
| `request` | method, URL, headers, form body — exactly what §7 describes |
| `expect` | `http_status`, `error` (null on success), and on success the token binding |

`expect.log_reason` is what should end up in the log. It must **not** appear in
the response body: a precise error message is a manual for forging the next
attempt.

## Running them

Freeze the clock to `now`, load `resolver` into the DID resolution stub, set up
the collection as described, POST the request, compare against `expect`. Run
`01-valid` before `05-jti-replay`; the rest are order-independent.

Done means: `01` yields a token bound to `cnf_jkt`, and all ten others are
refused with exactly the expected error.

## Regenerating

    python3 generate.py .

Deterministic — no randomness, no wall clock. Regenerating without changing
`generate.py` produces an empty diff.

## Two caveats

**The keys are derived from labels, not stored.** `generate.py` derives every
Ed25519 seed as `sha256("dpp-delegation-vector/" + label)`. No private key
material sits in the repository, and every identity here is a throwaway that
has never protected anything. A secret scanner may still flag the JWT strings;
they are signed test tokens over fictional identities, valid against nothing.

**The DIDs are synthetic.** They have the shape of `did:oyd` — the identifier
is the base58btc-encoded sha2-256 multihash of the DID document with the `id`
field blanked — but this reproduces oydid's *shape*, not necessarily its exact
canonicalisation. That is fine as long as resolution is stubbed from
`resolver`, which is what the fixtures are built for. If the pod additionally
verifies that a `did:oyd` is genuinely self-certifying, these vectors have to
be regenerated against real DIDs minted at the registrar. Decide that in the
architecture pass, and if so, say it in `Delegation.md`.

## Two things these vectors settle about the spec

**Rule 5 cannot mean what it currently says.** §8 rule 5 reads "`jti` not seen
before → store until `exp`", applied to the *delegation*. But §10 says the
delegation lives 90 days and is presented again at every token request, and §11
uses its `jti` as the revocation handle. A one-shot nonce and a 90-day reusable
artefact cannot be the same field: implemented literally, rule 5 would make
every delegation single-use, and the second token request of the day would be
refused as a replay.

Replay protection belongs on the short-lived artefacts, which are freshly
minted per request and are already covered: the client assertion (60 s, rule 7)
and the DPoP proof (30 s, rule 9). The delegation's `jti` is a *name*, checked
against the revocation denylist — which is what `collection.revoked_delegation_jti`
is for in these fixtures.

`05-jti-replay` therefore replays the **client assertion** of `01-valid`, not
the delegation. §8 rule 5 should be reworded accordingly.

**§8 and §14 disagree on error codes.** §8 says every failure is
`invalid_grant`; §14 maps the DPoP case to `invalid_dpop_proof` and the scope
case to `insufficient_scope`. These vectors follow §14, because RFC 9449 and
RFC 6750 prescribe those two codes. §8 should read "`invalid_grant`, unless §14
names a more specific code".

## Where the jti store commits

Every vector carries distinct `jti` values, except the one replay that is the
point of `05`. That makes the set order-independent no matter whether an
implementation records a `jti` when the rule passes or only once the whole
request succeeds — which is deliberate, because that choice is a real one and
should not be forced by an artefact of the fixtures. Note the trade-off when
you make it: committing on rule-pass lets anyone burn a legitimate client
assertion by sending a request that fails later.
