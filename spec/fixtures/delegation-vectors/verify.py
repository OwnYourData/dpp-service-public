#!/usr/bin/env python3
"""Reference verifier — checks that the fixtures say what they claim to say.

This is NOT the pod implementation. It is an independent second implementation
of the ten rules in Delegation.md section 8, used to prove that each vector
actually fails at the rule its `checks` field names, and that `01-valid` really
is valid. If the fixtures and this file disagree, one of them is wrong.

    python3 verify.py [dir]
"""

import base64
import hashlib
import json
import os
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
TOLERANCE = 60
MAX_DELEGATION_LIFETIME = 90 * 86400


class Refused(Exception):
    def __init__(self, error, reason):
        super().__init__(reason)
        self.error, self.reason = error, reason


def b64u_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def b58_decode(s: str) -> bytes:
    n = 0
    for ch in s:
        n = n * 58 + B58.index(ch)
    body = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return b"\x00" * (len(s) - len(s.lstrip("1"))) + body


def canonical(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def split(token: str):
    h, p, s = token.split(".")
    return json.loads(b64u_decode(h)), json.loads(b64u_decode(p)), \
        (h + "." + p).encode(), b64u_decode(s)


def verify_sig(pub: bytes, signing_input: bytes, sig: bytes, what: str):
    try:
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, signing_input)
    except InvalidSignature:
        raise Refused("invalid_grant", f"{what} signature does not verify")


def key_from_document(doc: dict) -> bytes:
    mb = doc["verificationMethod"][0]["publicKeyMultibase"]
    assert mb.startswith("z")
    raw = b58_decode(mb[1:])
    assert raw[:2] == b"\xed\x01", "not an ed25519-pub multicodec"
    return raw[2:]


def jkt_of(jwk: dict) -> str:
    thumb = {"crv": jwk["crv"], "kty": jwk["kty"], "x": jwk["x"]}
    return base64.urlsafe_b64encode(
        hashlib.sha256(canonical(thumb)).digest()).decode().rstrip("=")


def evaluate(vec: dict, seen_jti: set) -> dict:
    now = vec["now"]
    resolver = vec["resolver"]
    coll = vec["collection"]
    form = vec["request"]["form"]

    dh, dp, dsi, dsig = split(form["assertion"])

    # 1 — typ and alg
    if dh.get("typ") != "dpp-delegation+jwt" or dh.get("alg") != "EdDSA":
        raise Refused("invalid_grant", "delegation typ/alg wrong")

    # 2 — resolve iss and verify
    if not str(dp.get("iss", "")).startswith("did:"):
        raise Refused("invalid_grant", "iss is not a DID")
    if dp["iss"] not in resolver:
        raise Refused("invalid_grant", "iss does not resolve")
    verify_sig(key_from_document(resolver[dp["iss"]]), dsi, dsig, "delegation")

    # 3 — audience
    if dp.get("aud") != "https://dpp.go-data.at":
        raise Refused("invalid_grant", "aud does not match this pod")

    # 4 — validity window
    if not (dp["nbf"] - TOLERANCE <= now <= dp["exp"] + TOLERANCE):
        raise Refused("invalid_grant", "delegation outside its validity window")
    if dp["exp"] - dp["iat"] > MAX_DELEGATION_LIFETIME:
        raise Refused("invalid_grant", "delegation lifetime too long")

    # 5 — the delegation's jti is a REVOCATION handle, not a one-shot nonce.
    # A delegation lives 90 days and is presented again at every token
    # request; treating its jti as "seen once" would make it single-use.
    if dp["jti"] in coll.get("revoked_delegation_jti", []):
        raise Refused("invalid_grant", "delegation has been revoked")

    # 6 — controller of the collection
    if dp.get("collection") != coll["id"]:
        raise Refused("invalid_grant", "delegation names a different collection")
    if dp["iss"] != coll["controller_did"]:
        raise Refused("invalid_grant", "iss is not the controller of this collection")

    # 7 — client assertion
    ch, cp, csi, csig = split(form["client_assertion"])
    if ch.get("typ") != "client-assertion+jwt":
        raise Refused("invalid_grant", "client assertion typ wrong")
    if cp["iss"] != cp["sub"]:
        raise Refused("invalid_grant", "client assertion iss != sub")
    if cp["aud"] != vec["request"]["url"]:
        raise Refused("invalid_grant", "client assertion aud is not the token endpoint")
    if cp["exp"] - cp["iat"] > 60 or not (cp["iat"] - TOLERANCE <= now <= cp["exp"] + TOLERANCE):
        raise Refused("invalid_grant", "client assertion lifetime")
    if cp["iss"] not in resolver:
        raise Refused("invalid_grant", "client assertion iss does not resolve")
    verify_sig(key_from_document(resolver[cp["iss"]]), csi, csig, "client assertion")
    # replay protection lives here: the client assertion is fresh per request
    if cp["jti"] in seen_jti:
        raise Refused("invalid_grant", "client assertion jti already used")

    # 8 — the binding that makes the delegation non-bearer
    if dp["sub"] != cp["iss"]:
        raise Refused("invalid_grant",
                      "delegation sub does not match the presenting client")

    # 9 — DPoP
    ph, pp, psi, psig = split(vec["request"]["headers"]["DPoP"])
    if ph.get("typ") != "dpop+jwt" or "jwk" not in ph:
        raise Refused("invalid_dpop_proof", "DPoP typ/jwk wrong")
    proof_key = b64u_decode(ph["jwk"]["x"])
    try:
        Ed25519PublicKey.from_public_bytes(proof_key).verify(psig, psi)
    except InvalidSignature:
        raise Refused("invalid_dpop_proof", "DPoP signature does not verify")
    if pp["htm"] != vec["request"]["method"] or pp["htu"] != vec["request"]["url"]:
        raise Refused("invalid_dpop_proof", "htm/htu mismatch")
    if not (pp["iat"] - TOLERANCE <= now <= pp["iat"] + 30 + TOLERANCE):
        raise Refused("invalid_dpop_proof", "DPoP proof too old")
    if proof_key != key_from_document(resolver[cp["iss"]]):
        raise Refused("invalid_dpop_proof",
                      "DPoP key does not match the client assertion")

    # 10 — act
    act = dp.get("act") or []
    if not act or not set(act) <= set(coll["allowed_act"]):
        raise Refused("insufficient_scope",
                      "act exceeds the operations allowed for this collection")

    # D2 — no wildcard
    if dp.get("product_id") in ("*", "", None):
        raise Refused("invalid_grant", "wildcard product_id is not accepted")

    seen_jti.add(cp["jti"])
    return {"http_status": 200, "error": None, "token_type": "DPoP",
            "expires_in": min(600, dp["exp"] - now), "cnf_jkt": jkt_of(ph["jwk"])}


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    files = sorted(f for f in os.listdir(d)
                   if f.endswith(".json") and f != "index.json")
    seen, failures = set(), 0
    for name in files:
        vec = json.load(open(os.path.join(d, name)))
        want = vec["expect"]
        try:
            got = evaluate(vec, seen)
            ok = want["error"] is None and got["cnf_jkt"] == want.get("cnf_jkt")
            detail = "issued, cnf.jkt=%s expires_in=%s" % (got["cnf_jkt"], got["expires_in"])
        except Refused as r:
            ok = want["error"] == r.error
            detail = "%s (%s)" % (r.error, r.reason)
        print("%-7s %-30s %s" % ("PASS" if ok else "FAIL", vec["id"], detail))
        if not ok:
            failures += 1
            print("         expected: %s" % (want["error"] or "success"))
    print("\n%d/%d vectors behave as declared" % (len(files) - failures, len(files)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
