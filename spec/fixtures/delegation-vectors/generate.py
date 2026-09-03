#!/usr/bin/env python3
"""Generate the delegation conformance vectors.

Deterministic: no randomness, no wall clock. Running this twice produces
byte-identical output, so a regenerated fixture set shows up as an empty diff.

Requires only the standard library plus `cryptography`.

    python3 generate.py [output-dir]

See README.md in the output directory for the fixture format.
"""

import hashlib
import json
import os
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# --------------------------------------------------------------------------
# fixed parameters — mirror the running example in docs/Delegation.md
# --------------------------------------------------------------------------

NOW = 1786960000                      # the anchor every vector freezes the clock to
DAY = 86400
POD = "https://dpp.go-data.at"
TOKEN_ENDPOINT = POD + "/oauth/token"
COLLECTION = "4"
PRODUCT_ID = "https://id.lumina.example/01/09520123456791"
ALLOWED_ACT = ["create", "update", "delete"]
DELEGATION_LIFETIME = 90 * DAY

GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"
CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

# --------------------------------------------------------------------------
# base64url / base58btc / multibase
# --------------------------------------------------------------------------

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b64u(raw: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b58(raw: bytes) -> str:
    n = int.from_bytes(raw, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return "1" * (len(raw) - len(raw.lstrip(b"\x00"))) + out


def canonical(obj) -> bytes:
    """Sorted keys, no insignificant whitespace. Used for hashing only."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


# --------------------------------------------------------------------------
# keys and identities
# --------------------------------------------------------------------------
# Seeds are derived from a label, so no private key material is stored in the
# repository. Every party below is a throwaway test identity; none of these
# keys has ever protected anything.


def key_for(label: str) -> Ed25519PrivateKey:
    seed = hashlib.sha256(("dpp-delegation-vector/" + label).encode()).digest()
    return Ed25519PrivateKey.from_private_bytes(seed)


def public_multibase(key: Ed25519PrivateKey) -> str:
    from cryptography.hazmat.primitives import serialization
    raw = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return "z" + b58(b"\xed\x01" + raw)          # multicodec ed25519-pub


def public_raw(key: Ed25519PrivateKey) -> bytes:
    from cryptography.hazmat.primitives import serialization
    return key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )


def jwk(identity) -> dict:
    """RFC 7517 public JWK. Accepts an identity dict or a raw key."""
    key = identity["key"] if isinstance(identity, dict) else identity
    return {"crv": "Ed25519", "kty": "OKP", "x": b64u(public_raw(key))}


def jkt(identity) -> str:
    """RFC 7638 thumbprint. For OKP the required members are crv, kty, x."""
    return b64u(hashlib.sha256(canonical(jwk(identity))).digest())


def did_document(key: Ed25519PrivateKey, placeholder: str) -> dict:
    return {
        "@context": "https://www.w3.org/ns/did/v1",
        "id": placeholder,
        "verificationMethod": [{
            "id": placeholder + "#key-doc",
            "type": "Ed25519VerificationKey2020",
            "controller": placeholder,
            "publicKeyMultibase": public_multibase(key),
        }],
        "authentication": [placeholder + "#key-doc"],
    }


def make_identity(label: str) -> dict:
    """A self-certifying DID: the identifier is the hash of its own document.

    Computed with the identifier field blanked, because it cannot contain its
    own hash. NOTE: this reproduces the *shape* of did:oyd, not necessarily
    oydid's exact canonicalisation — see the caveat in README.md.
    """
    key = key_for(label)
    stub = did_document(key, "")
    digest = hashlib.sha256(canonical(stub)).digest()
    did = "did:oyd:z" + b58(b"\x12\x20" + digest)      # multihash sha2-256
    return {"label": label, "key": key, "did": did,
            "document": did_document(key, did)}


HOLDER = make_identity("holder")            # economic operator, controller of the collection
SERVICE = make_identity("service")          # the mandated DPP Service
OTHER_HOLDER = make_identity("other-holder")  # not the controller — vector 06
OTHER_SERVICE = make_identity("other-service")  # not the delegate — vector 07
STRAY = make_identity("stray-dpop-key")     # unrelated key — vector 08


# --------------------------------------------------------------------------
# JWT
# --------------------------------------------------------------------------

def jws(identity, typ: str, payload: dict, extra_header: dict = None,
        break_signature: bool = False) -> str:
    header = {"alg": "EdDSA", "typ": typ}
    if extra_header:
        header.update(extra_header)
    else:
        header["kid"] = identity["did"] + "#key-doc"
    signing_input = (b64u(canonical(header)) + "." + b64u(canonical(payload))).encode()
    sig = identity["key"].sign(signing_input)
    if break_signature:
        sig = bytes([sig[0] ^ 0xFF]) + sig[1:]
    return signing_input.decode() + "." + b64u(sig)


def jti_for(label: str) -> str:
    """Deterministic, distinct per artefact. Reusing one is what vector 05 does."""
    return hashlib.sha256(("dpp-delegation-vector/jti/" + label).encode()).hexdigest()[:16]


def delegation(sub=None, aud=POD, collection=COLLECTION, product_id=PRODUCT_ID,
               act=None, iat=NOW, exp=None, jti=None, tag=None,
               issuer=None, broken=False) -> str:
    issuer = issuer or HOLDER
    return jws(issuer, "dpp-delegation+jwt", {
        "iss": issuer["did"],
        "sub": sub or SERVICE["did"],
        "aud": aud,
        "collection": collection,
        "product_id": product_id,
        "act": act if act is not None else ["create", "update", "delete"],
        "purpose": "dpp-hosting",
        "iat": iat,
        "nbf": iat,
        "exp": exp if exp is not None else iat + DELEGATION_LIFETIME,
        "jti": jti or jti_for("delegation/" + (tag or "default")),
    }, break_signature=broken)


def client_assertion(identity=None, jti=None, tag=None) -> str:
    identity = identity or SERVICE
    jti = jti or jti_for("client-assertion/" + (tag or "default"))
    return jws(identity, "client-assertion+jwt", {
        "iss": identity["did"],
        "sub": identity["did"],
        "aud": TOKEN_ENDPOINT,
        "iat": NOW,
        "exp": NOW + 60,
        "jti": jti,
    })


def dpop(identity=None, htm="POST", htu=TOKEN_ENDPOINT, jti=None, tag=None) -> str:
    identity = identity or SERVICE
    jti = jti or jti_for("dpop/" + (tag or "default"))
    return jws(identity, "dpop+jwt",
               {"htm": htm, "htu": htu, "iat": NOW, "jti": jti},
               extra_header={"jwk": jwk(identity)})


# --------------------------------------------------------------------------
# vectors
# --------------------------------------------------------------------------

def vector(vid, description, checks, assertion, ca, proof, expect,
           collection_controller=None, preconditions=None, resolver_extra=None):
    resolver = {i["did"]: i["document"] for i in (HOLDER, SERVICE)}
    for i in (resolver_extra or []):
        resolver[i["did"]] = i["document"]
    return {
        "id": vid,
        "description": description,
        "checks": checks,
        "now": NOW,
        "resolver": resolver,
        "collection": {
            "id": COLLECTION,
            "controller_did": (collection_controller or HOLDER)["did"],
            "allowed_act": ALLOWED_ACT,
            "revoked_delegation_jti": [],
        },
        "preconditions": preconditions or [],
        "request": {
            "method": "POST",
            "url": TOKEN_ENDPOINT,
            "headers": {
                "DPoP": proof,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            "form": {
                "grant_type": GRANT_TYPE,
                "assertion": assertion,
                "client_assertion_type": CLIENT_ASSERTION_TYPE,
                "client_assertion": ca,
            },
        },
        "expect": expect,
    }


def ok(**over):
    e = {"http_status": 200, "error": None,
         "token_type": "DPoP", "expires_in": 600, "cnf_jkt": jkt(SERVICE)}
    e.update(over)
    return e


def refused(error, reason):
    return {"http_status": 400, "error": error, "log_reason": reason,
            "note": "the reason belongs in the log, never in the response body"}


def build():
    v = []

    v.append(vector(
        "01-valid",
        "A complete, well-formed request. The only vector that has to succeed.",
        "all ten rules of section 8",
        delegation(tag="01"), client_assertion(tag="01"), dpop(tag="01"),
        ok()))

    v.append(vector(
        "02-bad-signature",
        "The delegation's signature has one flipped byte; everything else is valid.",
        "rule 2 — resolve iss, verify the signature against the document key",
        delegation(tag="02", broken=True), client_assertion(tag="02"), dpop(tag="02"),
        refused("invalid_grant", "delegation signature does not verify")))

    v.append(vector(
        "03-wrong-audience",
        "A delegation minted for a different pod, replayed here.",
        "rule 3 — aud must equal the pod's own base_url",
        delegation(tag="03", aud="https://other-pod.example"), client_assertion(tag="03"), dpop(tag="03"),
        refused("invalid_grant", "aud does not match this pod")))

    v.append(vector(
        "04-expired-delegation",
        "The delegation expired an hour ago; outside the 60 s tolerance.",
        "rule 4 — nbf <= now <= exp",
        delegation(tag="04", iat=NOW - 100 * DAY, exp=NOW - 3600), client_assertion(tag="04"), dpop(tag="04"),
        refused("invalid_grant", "delegation expired")))

    v.append(vector(
        "05-jti-replay",
        "The client assertion from 01 replayed verbatim, with a fresh "
        "delegation. Run 01 first — this vector only means anything after it. "
        "Note what is replayed: the short-lived client assertion, NOT the "
        "delegation. The delegation is long-lived and is presented again at "
        "every token request by design.",
        "rule 7 — the client assertion's own jti store",
        delegation(tag="05"),
        client_assertion(jti=jti_for("client-assertion/01")),
        dpop(tag="05"),
        refused("invalid_grant", "client assertion jti already used"),
        preconditions=["01-valid"]))

    v.append(vector(
        "06-wrong-controller-did",
        "A valid, correctly signed delegation — but from someone who is not "
        "the controller of this collection. The signature check alone does not "
        "catch this.",
        "rule 6 — iss must be the collection's controller_did",
        delegation(tag="06", issuer=OTHER_HOLDER), client_assertion(tag="06"), dpop(tag="06"),
        refused("invalid_grant", "iss is not the controller of this collection"),
        resolver_extra=[OTHER_HOLDER]))

    v.append(vector(
        "07-sub-mismatch",
        "A delegation addressed to service A, presented by service B. This is "
        "the vector that matters most: without rule 8 the delegation is a "
        "bearer artifact that anyone who has seen it can present.",
        "rule 8 — the delegation's sub must equal the client assertion's iss",
        delegation(tag="07", sub=SERVICE["did"]),
        client_assertion(tag="07", identity=OTHER_SERVICE),
        dpop(tag="07", identity=OTHER_SERVICE),
        refused("invalid_grant", "delegation sub does not match the presenting client"),
        resolver_extra=[OTHER_SERVICE]))

    v.append(vector(
        "08-dpop-key-mismatch",
        "The DPoP proof is signed with a key unrelated to the client assertion, "
        "so the token would be bound to a key the caller does not control.",
        "rule 9 — the DPoP proof must be made with the client's own key",
        delegation(tag="08"), client_assertion(tag="08"), dpop(tag="08", identity=STRAY),
        refused("invalid_dpop_proof", "DPoP key does not match the client assertion"),
        resolver_extra=[STRAY]))

    v.append(vector(
        "09-act-exceeds-collection",
        "act asks for an operation the collection does not permit at all.",
        "rule 10 — act must be a subset of the collection's allowed operations",
        delegation(tag="09", act=["create", "update", "delete", "purge"]),
        client_assertion(tag="09"), dpop(tag="09"),
        refused("insufficient_scope", "act exceeds the operations allowed for this collection")))

    v.append(vector(
        "10-unknown-act-value",
        "act contains 'read'. Reserved by decision D3 but not issued today, so "
        "it must be refused — and refused without the verifier having to know "
        "a closed enum of values.",
        "decision D3 — act is extensible, unknown values fail closed",
        delegation(tag="10", act=["create", "read"]), client_assertion(tag="10"), dpop(tag="10"),
        refused("insufficient_scope", "act contains a reserved value that is not issued")))

    v.append(vector(
        "11-wildcard-product-id",
        "product_id is '*'. Ruled out by decision D2 — this vector exists so "
        "that reintroducing a wildcard breaks a test rather than passing "
        "quietly.",
        "decision D2 — no wildcard, exactly one product per delegation",
        delegation(tag="11", product_id="*"), client_assertion(tag="11"), dpop(tag="11"),
        refused("invalid_grant", "wildcard product_id is not accepted")))

    return v


README = """# Delegation conformance vectors

Fixture set for the delegation model in `docs/Delegation.md`. Eleven requests
against the token endpoint: one that has to succeed, ten that have to be
refused, each with the error code `Delegation.md` §15 prescribes.

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
delegation lives 90 days and is presented again at every token request, and §12
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

**§8 and §15 disagree on error codes.** §8 says every failure is
`invalid_grant`; §15 maps the DPoP case to `invalid_dpop_proof` and the scope
case to `insufficient_scope`. These vectors follow §15, because RFC 9449 and
RFC 6750 prescribe those two codes. §8 should read "`invalid_grant`, unless §15
names a more specific code".

## Where the jti store commits

Every vector carries distinct `jti` values, except the one replay that is the
point of `05`. That makes the set order-independent no matter whether an
implementation records a `jti` when the rule passes or only once the whole
request succeeds — which is deliberate, because that choice is a real one and
should not be forced by an artefact of the fixtures. Note the trade-off when
you make it: committing on rule-pass lets anyone burn a legitimate client
assertion by sending a request that fails later.
"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    vectors = build()
    for vec in vectors:
        with open(os.path.join(out, vec["id"] + ".json"), "w") as fh:
            json.dump(vec, fh, indent=2, sort_keys=False)
            fh.write("\n")
    with open(os.path.join(out, "README.md"), "w") as fh:
        fh.write(README)
    index = {
        "anchor_now": NOW,
        "pod": POD,
        "token_endpoint": TOKEN_ENDPOINT,
        "identities": {i["label"]: i["did"]
                       for i in (HOLDER, SERVICE, OTHER_HOLDER, OTHER_SERVICE, STRAY)},
        "vectors": [{"id": v["id"], "checks": v["checks"],
                     "expect": v["expect"]["error"] or "success"} for v in vectors],
    }
    with open(os.path.join(out, "index.json"), "w") as fh:
        json.dump(index, fh, indent=2)
        fh.write("\n")
    print("wrote %d vectors + README.md + index.json to %s" % (len(vectors), out))


if __name__ == "__main__":
    main()
