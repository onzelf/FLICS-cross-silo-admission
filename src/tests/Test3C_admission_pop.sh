#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test — PoP binding (cnf.jkt) positive + negative controls
#
#  (T1) ALLOW:  ECT minted for HOLDER_OK + DPoP signed by HOLDER_OK
#  (T2) DENY :  same ECT (HOLDER_OK) + DPoP signed by HOLDER_BAD
#
# Uses make_dpop_jwt_eddsa.py exactly like Test3B_run_predict_via_hub.sh.
#
# Usage:
#   ./TestX_poppair_allow_deny.sh <envelope_id>
# ============================================================

ENVELOPE_ID="${1:-}"
if [[ -z "${ENVELOPE_ID}" ]]; then
  echo "Usage: $0 <envelope_id>" >&2
  exit 1
fi

# -------- Config (override via env) --------
HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"

ISSUER_A_CONTAINER="${ISSUER_A_CONTAINER:-issuer-hospitala}"
ISSUER_B_CONTAINER="${ISSUER_B_CONTAINER:-issuer-hospitalb}"

# DPoP HTU must match verifier expectation (same as your Test3B)
HTU="${HTU:-https://verifier.local/admission/check}"

# Test identities (override if you want Alice/Bob etc.)
ORG_OK="${ORG_OK:-org://HospitalA}"
HOLDER_OK="${HOLDER_OK:-Audrey}"
COHORT_OK="${COHORT_OK:-EVEN_ONLY}"

ORG_BAD="${ORG_BAD:-org://HospitalB}"
HOLDER_BAD="${HOLDER_BAD:-Bob}"

# Prediction parameters (choose an allowed digit for EVEN_ONLY)
DIGIT_ALLOW="${DIGIT_ALLOW:-2}"
TOPK="${TOPK:-3}"

# Registration endpoints (issuer proxies, same as Test3B)
ISSUER_A_PROXY_HOST="${ISSUER_A_PROXY_HOST:-issuer-hospitala.local}"
ISSUER_B_PROXY_HOST="${ISSUER_B_PROXY_HOST:-issuer-hospitalb.local}"
ISSUER_PROXY_IP="${ISSUER_PROXY_IP:-192.168.1.25}"
ISSUER_PROXY_PORT="${ISSUER_PROXY_PORT:-9443}"

# Admin mTLS material (same paths as your Test3B)
CA_CRT="${CA_CRT:-../vfp-governance/verifier/certs/ca.crt}"
ADMIN_CRT="${ADMIN_CRT:-../vfp-governance/verifier/certs/HospitalA-admin.crt}"
ADMIN_KEY="${ADMIN_KEY:-../vfp-governance/verifier/certs/HospitalA-admin.key}"

# Set SKIP_REGISTER=1 if members already registered
SKIP_REGISTER="${SKIP_REGISTER:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need jq
need python3
need curl
need docker

mint_ect_via_issuer() {
  local issuer_container="$1"
  local sub="$2"
  local cohort="$3"

  docker exec -i "${issuer_container}" python3 - <<PY
import json
import requests
payload = {"sub": "${sub}", "cohort": "${cohort}"}
r = requests.post("http://127.0.0.1:8080/mint", json=payload, timeout=20)
print(json.dumps({"status": r.status_code, "body": r.json() if r.headers.get('content-type','').startswith('application/json') else r.text}))
PY
}

extract_ect() {
  jq -r '.body.ect // .body.ect_jws // empty'
}

make_dpop() {
  local priv_hex="$1"
  local pub_b64="$2"
  local nonce="$3"
  local jti="$4"
  python3 ../tools/make_dpop_jwt_eddsa.py "${priv_hex}" "${pub_b64}" "${nonce}" "${jti}" "POST" "${HTU}"
}

call_hub_predict() {
  local cohort="$1"
  local digit="$2"
  local jti="$3"
  local topk="$4"
  local ect="$5"
  local dpop="$6"
  local nonce="$7"

  curl -sS "${HUB_URL}/predict" \
    -H "Content-Type: application/json" \
    -H "Authorization: ECT ${ect}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    -d '{
      "envelope_id": "'"${ENVELOPE_ID}"'",
      "cohort": "'"${cohort}"'",
      "digit": '"${digit}"',
      "jti": "'"${jti}"'",
      "topk": '"${topk}"'
    }'
}

register_member_via_proxy() {
  local proxy_host="$1"  # issuer-hospitala.local
  local org="$2"
  local who="$3"
  local pub_b64="$4"
  local jkt="$5"

  curl -vk \
    --resolve "${proxy_host}:${ISSUER_PROXY_PORT}:${ISSUER_PROXY_IP}" \
    --cacert "${CA_CRT}" \
    --cert  "${ADMIN_CRT}" \
    --key   "${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    --data "{\"org_id\":\"${org}\",\"member_id\":\"${who}\",\"sub\":\"${who}\",\"pub_b64\":\"${pub_b64}\",\"jkt\":\"${jkt}\"}" \
    "https://${proxy_host}:${ISSUER_PROXY_PORT}/members/register" >/dev/null
}

echo "== 0) (Optional) register flower backend in Hub =="
curl -sS -X POST "${HUB_URL}/backend/register" \
  -H "Content-Type: application/json" \
  -d '{"type":"flower","url":"http://flower-server:8081"}' | jq . || true
echo

# ------------------------------------------------------------
# 1) Ensure holder keys exist + register members (optional)
# ------------------------------------------------------------
echo "== 1) Ensure local holder keys exist =="
python3 ../tools/gen_member_keys.py --org "${ORG_OK}"  --who "${HOLDER_OK}"  | sed 's/^/[keys] /' || true
python3 ../tools/gen_member_keys.py --org "${ORG_BAD}" --who "${HOLDER_BAD}" | sed 's/^/[keys] /' || true

PUB_OK=$(cat "holder_keys/${HOLDER_OK}.pubb64")
PRIV_OK=$(cat "holder_keys/${HOLDER_OK}.privhex")
JKT_OK=$(cat "holder_keys/${HOLDER_OK}.jkt")

PUB_BAD=$(cat "holder_keys/${HOLDER_BAD}.pubb64")
PRIV_BAD=$(cat "holder_keys/${HOLDER_BAD}.privhex")
JKT_BAD=$(cat "holder_keys/${HOLDER_BAD}.jkt")

if [[ "${SKIP_REGISTER}" != "1" ]]; then
  echo
  echo "== 2) Register members via issuer proxies (mTLS admin) =="
  register_member_via_proxy "${ISSUER_A_PROXY_HOST}" "${ORG_OK}"  "${HOLDER_OK}"  "${PUB_OK}"  "${JKT_OK}"
  register_member_via_proxy "${ISSUER_B_PROXY_HOST}" "${ORG_BAD}" "${HOLDER_BAD}" "${PUB_BAD}" "${JKT_BAD}"
  echo "Registered: ${HOLDER_OK} in ${ORG_OK}, ${HOLDER_BAD} in ${ORG_BAD}"

  cp -v "holder_keys/${HOLDER_OK}.privhex" ../vfp-governance/verifier/vault/holder_keys/ 
  cp -v "holder_keys/${HOLDER_BAD}.privhex" ../vfp-governance/verifier/vault/holder_keys/ 
else
  echo
  echo "== 2) SKIP_REGISTER=1 (assuming members already registered) =="
fi

# ------------------------------------------------------------
# 2) Mint ECT for HOLDER_OK and run two PoP tests
# ------------------------------------------------------------
echo
echo "== 3) Mint ECT for ${HOLDER_OK} (${COHORT_OK}) via ${ISSUER_A_CONTAINER} =="
MINT_RAW="$(mint_ect_via_issuer "${ISSUER_A_CONTAINER}" "${HOLDER_OK}" "${COHORT_OK}")"
echo "${MINT_RAW}" | jq .
ECT="$(echo "${MINT_RAW}" | extract_ect)"
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

# T1: PoP signed by correct holder
NONCE1="nonce-t1-$(date +%s)"
JTI1="jti-t1-$(date +%s)"
DPOP1="$(make_dpop "${PRIV_OK}" "${PUB_OK}" "${NONCE1}" "${JTI1}")"

echo
echo "=== T1 (EXPECT ALLOW): ECT(${HOLDER_OK}) + DPoP(${HOLDER_OK}) ==="
RESP1="$(call_hub_predict "${COHORT_OK}" "${DIGIT_ALLOW}" "${JTI1}" "${TOPK}" "${ECT}" "${DPOP1}" "${NONCE1}")"
echo "${RESP1}" | jq .
echo

# T2: same ECT but PoP signed by different holder => dpop_binding_mismatch
NONCE2="nonce-t2-$(date +%s)"
JTI2="jti-t2-$(date +%s)"
DPOP2="$(make_dpop "${PRIV_BAD}" "${PUB_BAD}" "${NONCE2}" "${JTI2}")"

echo "=== T2 (EXPECT DENY dpop_binding_mismatch): same ECT(${HOLDER_OK}) + DPoP(${HOLDER_BAD}) ==="
RESP2="$(call_hub_predict "${COHORT_OK}" "${DIGIT_ALLOW}" "${JTI2}" "${TOPK}" "${ECT}" "${DPOP2}" "${NONCE2}")"
echo "${RESP2}" | jq .

echo
echo "Done."
