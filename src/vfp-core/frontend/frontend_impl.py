import base64
import json
import os
import time
from typing import Dict, Tuple

import requests
from cryptography.hazmat.primitives.asymmetric import ed25519

RIGHTS_TEXT = """Members for FLICS PoC
Audrey (Hospital A): cohorts EVEN_ONLY, ODD_PLUS
Bob  (Hospital B): cohorts ODD_ONLY

Two-step UI:
============>
1) Admin tab mints a session capability token (SCT) for the selected user+cohort (issuer call).
2) User tab performs governed /predict using that SCT (Hub -> /admission/check -> service).
"""

# ---- Network targets ----
HUB_URL         = os.getenv("HUB_URL", "http://fc-hub:8080").rstrip("/")
ISSUER_A_URL    = os.getenv("ISSUER_A_URL", "http://issuer-hospitala:8080").rstrip("/")
ISSUER_B_URL    = os.getenv("ISSUER_B_URL", "http://issuer-hospitalb:8080").rstrip("/")
SIGNER_URL = os.getenv("SIGNER_URL", "http://holder-signer:8090").strip()

#HOLDER_KEYS_DIR = os.getenv("HOLDER_KEYS_DIR", "/vault/holder_keys")

# HTU convention used inside DPoP JWT (Hub will forward to verifier)
DPoP_HTU = os.getenv("DPoP_HTU", "https://verifier.local/admission/check")

'''
def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")

def _load_holder_sk(kid: str) -> ed25519.Ed25519PrivateKey:
    import pathlib, binascii
    p = pathlib.Path(HOLDER_KEYS_DIR) / f"{kid}.privhex"
    raw = binascii.unhexlify(p.read_text().strip())
    return ed25519.Ed25519PrivateKey.from_private_bytes(raw)

def _holder_pub_b64(sk: ed25519.Ed25519PrivateKey) -> str:
    return _b64u(sk.public_key().public_bytes_raw())

def _jws_eddsa(sk: ed25519.Ed25519PrivateKey, header: Dict, payload: Dict) -> str:
    h = _b64u(json.dumps(header, separators=(",", ":"), sort_keys=True).encode("utf-8"))
    p = _b64u(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8"))
    msg = f"{h}.{p}".encode("ascii")
    sig = sk.sign(msg)
    return f"{h}.{p}.{_b64u(sig)}"

def _make_dpop_and_nonce(sub: str, jti: str) -> Tuple[str, str]:
    sk = _load_holder_sk(sub)
    pub_b64 = _holder_pub_b64(sk)

    now = int(time.time())
    nonce = f"ui-nonce-{now}"

    header = {
        "typ": "dpop+jwt",
        "alg": "EdDSA",
        # RFC7638 thumbprint of this JWK will become the 'jkt' binding in your capability token.
        "jwk": {"kty": "OKP", "crv": "Ed25519", "x": pub_b64},
    }

    payload = {
        # bind proof to the exact request target
        "htu": DPoP_HTU,   # must match what the gateway verifies (scheme/host/path)
        "htm": "POST",
        "iat": now,
        "jti": jti,
        # optional anti-replay; if you later switch to server-issued nonces, keep the field
        "nonce": nonce,
    }

    dpop = _jws_eddsa(sk, header, payload)
    return dpop, nonce
'''
def _make_dpop_and_nonce(sub: str, jti: str) -> Tuple[str, str]:
    nonce = f"ui-nonce-{int(time.time())}"
    try:
        r = requests.post(
            f"{SIGNER_URL}/dpop/sign",
            json={
                "sub": sub,
                "htu": DPoP_HTU,
                "htm": "POST",
                "jti": jti,
                "nonce": nonce,
            },
            timeout=10,
        )
        if r.status_code != 200:
            raise RuntimeError(f"signer_http_{r.status_code}:{r.text}")
        out = r.json()
        dpop = out.get("dpop")
        if not dpop or dpop.count(".") < 2:
            raise RuntimeError(f"signer_bad_dpop:{out}")
        return dpop, nonce
    except Exception as e:
        # deterministic, readable failure
        raise RuntimeError(f"signer_error:{e}")


ISSUER_BY_ORG_ID = {
    "org://HospitalA": ISSUER_A_URL,   # e.g., http://issuer-hospitala:8080
    "org://HospitalB": ISSUER_B_URL,
}


def _issuer_for_org_id(org_id: str) -> str:
    try:
        return ISSUER_BY_ORG_ID[org_id]
    except KeyError:
        raise ValueError(f"unknown_org_id:{org_id}")


def ui_members_all() -> Dict:
    """
    Aggregate member registries from both issuers (internal :8080),
    return a single list for UI dropdown.
    """
    try:
        out_members = []

        for org_name, issuer in [("HospitalA", ISSUER_A_URL), ("HospitalB", ISSUER_B_URL)]:
            r = requests.get(f"{issuer}/members", timeout=15)
            j = r.json()
            if r.status_code != 200:
                return {"ok": False, "error": {"issuer": issuer, "detail": j}}
            for m in j.get("members", []):
                m2 = dict(m)
                m2["org_id"] = j.get("org")          # org://HospitalA
                m2["org_name"] = org_name            # HospitalA (UI label only)
                # normalize holder identity field for UI:
                if "sub" not in m2:
                    m2["sub"] = m2.get("member_id")
                out_members.append(m2)

        out_members.sort(key=lambda x: (x.get("org_id",""), x.get("sub","")))
        return {"ok": True, "count": len(out_members), "members": out_members}
    except Exception as e:
        return {"ok": False, "error": f"members_error:{e}"}

 

def ui_mint(org_id: str, sub: str, cohort: str, nbf: str = None, exp: str = None) -> Dict:
    try:
        issuer = _issuer_for_org_id(org_id)
        payload = {"sub": sub, "cohort": cohort}
        if nbf is not None: payload["nbf"] = nbf
        if exp is not None: payload["exp"] = exp

        r = requests.post(f"{issuer}/mint", json=payload, timeout=15)
        out = r.json()
        if r.status_code != 200:
            return {"ok": False, "error": out}

        ect = out.get("ect")
        if not ect:
            return {"ok": False, "error": "mint_failed:no_ect", "raw": out}

        return {"ok": True, "ect": ect, "issuer": issuer}
    except Exception as e:
        return {"ok": False, "error": f"mint_error:{e}"}


def ui_predict_with_ect(req) -> Dict:
    ect = (req.ect or "").strip()
    if not ect or ect.count(".") != 2:
        return {"admission": {"allow": False, "reason": "bad_ect_format"}, "executed": False}

    dpop, nonce = _make_dpop_and_nonce(req.sub, req.jti)

    try:
        r = requests.post(
            f"{HUB_URL}/predict",
            headers={
                "Authorization": f"ECT {ect}",
                "DPoP": dpop,
                "X-DPoP-Nonce": nonce,
                "Content-Type": "application/json",
            },
            json={
                "envelope_id": req.envelope_id,
                "cohort": req.cohort,
                "digit": req.digit,
                "topk": req.topk,
                "jti": req.jti,
            },
            timeout=30,
        )
        return r.json()
    except Exception as e:
        return {"admission": {"allow": False, "reason": f"hub_error:{e}"}, "executed": False}
